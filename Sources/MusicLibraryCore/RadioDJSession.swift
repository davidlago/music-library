import Foundation
import Observation

/// One segment with the Radio DJ on one page: it opens by talking about the page's album or artist, then answers the
/// listener. Lives only as long as the page shows it (`stop()` ends it); nothing is saved but the spend.
@MainActor @Observable
public final class RadioDJSession {
    public struct Source: Hashable, Sendable, Identifiable {
        public var title: String
        public var url: URL
        public var id: URL { url }
        /// "en.wikipedia.org" without "www.".
        public var host: String {
            let host = url.host() ?? url.absoluteString
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    public struct Line: Identifiable, Equatable, Sendable {
        public enum Role: Sendable { case dj, listener }
        public let id: UUID
        public var role: Role
        public var text: String
        public var sources: [Source] = []

        init(role: Role, text: String) { id = UUID(); self.role = role; self.text = text }
    }

    public enum Activity: Equatable, Sendable {
        case idle
        /// Waiting for the first words.
        case warmingUp
        case searching(String)
        case reading(String)
        /// Looking through the listener's own collection (`search_collection`).
        case browsing(String)
        /// Opening the Shop on an album (`open_shop`).
        case shopping(String)
        case speaking
    }

    public let name: String
    /// Questions to start with, until the first is asked (the first is about what's on screen).
    public private(set) var suggestions: [String] = []
    /// What the conversation is about: the page it started on, then the last page the listener asked from.
    public private(set) var subject: RadioDJSubject
    public private(set) var lines: [Line] = []
    public private(set) var activity: Activity = .idle
    public private(set) var error: String?
    /// What this segment has cost so far, at list prices.
    public private(set) var cost = 0.0
    /// Wikipedia articles checked for artists and albums the DJ mentioned that aren't in the collection
    /// (`WikipediaArticleFinder.key`); only these are linked.
    public private(set) var webPages: [String: URL] = [:]
    public var isBusy: Bool { activity != .idle }

    /// Changes whenever the bottom of the conversation does (a line, the reply growing, the status, an error), for
    /// views to keep it in sight.
    public var scrollKey: String {
        "\(lines.count)|\(lines.last?.text.count ?? 0)|\(lines.last?.sources.count ?? 0)|\(activity)|\(error ?? "")"
    }

    @ObservationIgnored private var history: [ClaudeMessage] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// The page the DJ came on from, told (with the time then) before the first question.
    @ObservationIgnored private var openedFrom: RadioDJSubject?
    /// The last request that failed, to try again.
    @ObservationIgnored private var failed: (text: String, display: String?)?
    @ObservationIgnored private var countedSegment = false
    /// A tool ran since the last words: the next words start a new paragraph.
    @ObservationIgnored private var breakBeforeText = false
    @ObservationIgnored private let client: ClaudeClient
    /// The listener's collection, for `search_collection` (nil: no tool).
    @ObservationIgnored private let library: RadioDJLibrary?
    /// Links the DJ's references to what the listener owns (nil: plain text).
    @ObservationIgnored private var linker: RadioDJLinker?
    @ObservationIgnored private let listenerName: String?
    /// Checks articles before they're linked (nil: none are).
    @ObservationIgnored private let wikipedia: WikipediaArticleFinder?
    /// Opens the Shop for `open_shop` and says what it found (nil: no tool, as on the phone).
    @ObservationIgnored private let shop: (@MainActor (RadioDJShopRequest) async -> String)?
    @ObservationIgnored private var checkedWeb = Set<String>()
    /// The system prompt, fixed for the whole conversation: the API ties the model's thinking to it, so a changed one
    /// makes every earlier turn invalid ("bound to a different conversation"). Later pages go in the messages.
    @ObservationIgnored private let system: [String]
    @ObservationIgnored private let onUsage: @MainActor (RadioDJTally) -> Void

    /// `now`: the time the opener tells the DJ (it greets for the time of day).
    public init(name: String, subject: RadioDJSubject, client: ClaudeClient, library: RadioDJLibrary? = nil,
                linker: RadioDJLinker? = nil, listenerName: String? = nil, wikipedia: WikipediaArticleFinder? = nil,
                shop: (@MainActor (RadioDJShopRequest) async -> String)? = nil, now: @escaping () -> Date = Date.init,
                onUsage: @escaping @MainActor (RadioDJTally) -> Void) {
        self.name = name; self.subject = subject; self.client = client; self.library = library
        self.linker = linker; self.listenerName = listenerName; self.wikipedia = wikipedia; self.shop = shop
        self.now = now; self.onUsage = onUsage
        system = [RadioDJ.persona(name: name, listener: listenerName, canSearchCollection: library != nil, canShop: shop != nil),
                  subject.context]
    }

    @ObservationIgnored private let now: () -> Date

    /// A DJ line as text with links to the collection and play buttons (a reference still being written at the end
    /// of the line streaming in is hidden).
    public func segments(_ line: Line) -> [RadioDJSegment] {
        let streaming = isBusy && line.id == lines.last?.id
        if let linker { return linker.render(line.text, streaming: streaming, webPages: webPages) }
        return RadioDJLinker.plain(line.text, streaming: streaming)
    }

    /// Goes on the air (once): the app's greeting and suggested questions, with no request until one is asked.
    public func start() {
        guard !started else { return }
        started = true
        openedFrom = subject
        lines.append(Line(role: .dj, text: RadioDJ.greeting(name: name, listener: listenerName, subject: subject, at: now())))
        suggestions = RadioDJ.suggestions(for: subject, canSearchCollection: library != nil, canShop: shop != nil)
    }

    /// Whether `page` is another album or artist than the conversation is about.
    public func isElsewhere(_ page: RadioDJSubject?) -> Bool {
        guard let page else { return false }
        return page.topic != subject.topic
    }

    /// Sends what the listener wrote. `page`: the page they're on now; when it's another album or artist than the
    /// conversation is about, the message tells the DJ (with what the app knows about it) and it becomes the topic.
    public func send(_ text: String, page: RadioDJSubject? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        var message = text
        if let page, isElsewhere(page) {
            message = page.moveNote + "\n\n" + text
            subject = page
            linker?.setPage(page)
        }
        run(message, display: text)
    }

    public func retry() {
        guard let failed, !isBusy else { return }
        run(failed.text, display: failed.display, repeating: true)
    }

    /// Ends the segment: cancels a reply in progress.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Sends `text`; `display` is what shows as the listener's line (nil: nothing). The first question carries the
    /// opener, and counts the segment.
    private func run(_ text: String, display: String?, repeating: Bool = false) {
        error = nil
        failed = nil
        suggestions = []
        if let display, !repeating { lines.append(Line(role: .listener, text: display)) }
        let turnStart = history.count
        if history.isEmpty, let openedFrom {
            history.append(.user(RadioDJ.opener(openedFrom, at: now()) + "\n\n" + text))
            if !countedSegment {
                countedSegment = true
                var segment = RadioDJTally()
                segment.segments = 1
                onUsage(segment)
            }
        } else {
            history.append(.user(text))
        }
        let line = Line(role: .dj, text: "")
        lines.append(line)
        activity = .warmingUp
        task = Task {
            do {
                try await reply(into: line.id)
                if let finished = lines.first(where: { $0.id == line.id }) { checkWebPages(in: finished.text) }
            } catch {
                // Back to before the question, so it can be asked again.
                history.removeSubrange(turnStart...)
                let cancelled = error is CancellationError || Task.isCancelled
                if let i = lines.firstIndex(where: { $0.id == line.id }), lines[i].text.isEmpty || !cancelled { lines.remove(at: i) }
                if !cancelled {
                    self.error = error.localizedDescription
                    failed = (text, display)
                }
            }
            activity = .idle
        }
    }

    /// Streams the reply to the last user message: resumes when the server pauses a long turn, and runs collection
    /// searches and sends their results back until the DJ has answered.
    private func reply(into lineID: UUID) async throws {
        let tools = RadioDJ.tools + (library == nil ? [] : [RadioDJLibrary.tool, RadioDJLibrary.statsTool])
            + (shop == nil ? [] : [RadioDJShopRequest.tool])
        var resuming = false
        breakBeforeText = false
        for _ in 0..<RadioDJ.maxRounds {
            let request = ClaudeRequest(model: RadioDJ.model, maxTokens: RadioDJ.maxTokens, system: system,
                                        messages: history, tools: tools)
            let result = try await client.stream(request) { [weak self] event in await self?.show(event, in: lineID) }
            let tally = RadioDJTally.billing(usage: result.usage, requestedModel: RadioDJ.model, servedModel: result.model)
            cost += tally.dollars
            onUsage(tally)
            if result.stopReason == "refusal" { throw ClaudeError.refused }
            // A resumed turn continues the same assistant message.
            if resuming, let last = history.indices.last, history[last].role == "assistant" {
                history[last].content += result.content
            } else {
                history.append(ClaudeMessage(role: "assistant", content: result.content))
            }
            addSources(from: result.content, to: lineID)
            try Task.checkCancellation()
            switch result.stopReason {
            case "pause_turn":
                resuming = true
            case "tool_use" where !result.toolCalls.isEmpty:
                resuming = false
                history.append(ClaudeMessage(role: "user", content: await runTools(result.toolCalls)))
                try Task.checkCancellation()
            default:
                return
            }
        }
        // Rolled back by the caller, so the question can be asked again.
        throw ClaudeError.api("\(name) got lost in the stacks. Try asking again, maybe more simply.")
    }

    /// Looks up the Wikipedia articles of the artists and albums in a finished reply that aren't in the collection, a few
    /// at a time and each once per conversation; links appear as they're confirmed.
    private func checkWebPages(in text: String) {
        guard let wikipedia, let linker else { return }
        let wanted = linker.webCandidates(text).filter {
            checkedWeb.insert(WikipediaArticleFinder.key(kind: $0.kind, name: $0.name, artist: $0.artist)).inserted
        }
        guard !wanted.isEmpty else { return }
        Task {
            await withTaskGroup(of: (String, URL?).self) { group in
                for (i, item) in wanted.prefix(12).enumerated() {
                    if i >= 4 { if let (key, url) = await group.next() { if let url { webPages[key] = url } } }
                    group.addTask {
                        (WikipediaArticleFinder.key(kind: item.kind, name: item.name, artist: item.artist),
                         await wikipedia.article(kind: item.kind, name: item.name, artist: item.artist))
                    }
                }
                for await (key, url) in group { if let url { webPages[key] = url } }
            }
        }
    }

    /// One `tool_result` per call, all in one message. Collection searches run off the main thread; the Shop opens on it.
    private func runTools(_ calls: [JSONValue]) async -> [JSONValue] {
        var results: [JSONValue] = []
        for call in calls {
            let id = call["id"]?.string ?? ""
            let output: (text: String, isError: Bool)
            let input = call["input"] ?? .object([:])
            if call["name"]?.string == RadioDJLibrary.toolName, let library {
                output = await Task.detached(priority: .userInitiated) { library.run(input) }.value
            } else if call["name"]?.string == RadioDJLibrary.statsToolName, let library {
                output = await Task.detached(priority: .userInitiated) { library.runStats(input) }.value
            } else if call["name"]?.string == RadioDJShopRequest.toolName, let shop {
                switch RadioDJShopRequest.parse(input) {
                case .success(let request): output = (await shop(request), false)
                case .failure(let error): output = ("Invalid input: \(error.message).", true)
                }
            } else {
                output = ("Unknown tool.", true)
            }
            results.append(.object(["type": .string("tool_result"), "tool_use_id": .string(id),
                                    "content": .string(output.text), "is_error": .bool(output.isError)]))
        }
        return results
    }

    private func show(_ event: ClaudeStreamEvent, in lineID: UUID) {
        guard !Task.isCancelled else { return }
        switch event {
        case .text(let piece):
            if let i = lines.firstIndex(where: { $0.id == lineID }) {
                if breakBeforeText, !lines[i].text.isEmpty, !lines[i].text.hasSuffix("\n") { lines[i].text += "\n\n" }
                lines[i].text += piece
            }
            breakBeforeText = false
            activity = .speaking
        case .toolStarted(let name):
            breakBeforeText = true
            activity = switch name {
            case "web_fetch": .reading("")
            case RadioDJLibrary.toolName, RadioDJLibrary.statsToolName: .browsing("")
            case RadioDJShopRequest.toolName: .shopping("")
            default: .searching("")
            }
        case .toolInput(let name, let input):
            switch name {
            case "web_fetch": activity = .reading(input["url"]?.string.flatMap { URL(string: $0)?.host() } ?? "")
            case RadioDJLibrary.toolName: activity = .browsing(input["query"]?.string ?? "")
            case RadioDJLibrary.statsToolName: activity = .browsing(input["section"]?.string.map { "your \($0) stats" } ?? "")
            case RadioDJShopRequest.toolName: activity = .shopping(input["album"]?.string ?? "")
            default: activity = .searching(input["query"]?.string ?? "")
            }
        }
    }

    /// The pages the reply cites, once each, web links only.
    private func addSources(from content: [JSONValue], to lineID: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == lineID }) else { return }
        for block in content where block["type"]?.string == "text" {
            for citation in block["citations"]?.array ?? [] {
                guard let url = citation["url"]?.string.flatMap({ URL(webLink: $0) }),
                      !lines[i].sources.contains(where: { $0.url == url }) else { continue }
                let title = citation["title"]?.string ?? url.host() ?? url.absoluteString
                lines[i].sources.append(Source(title: title, url: url))
            }
        }
    }
}
