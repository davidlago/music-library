// XMLDocument (used to parse tidied HTML) is macOS only, and so is the library catalog.
#if os(macOS)
import Foundation

/// Reads the catalog's HTML pages and AJAX replies. Foundation's HTML reader (libxml2 via tidy) nests Aspen's
/// markup wrongly across results, so pages are cut into one fragment per result before they're parsed.
public enum CatalogParser {
    // MARK: Search results

    public static func parseResults(_ html: String, page: Int = 1) throws -> CatalogPage {
        let total: Int
        if let m = html.range(of: #"Showing [\d,]+ - [\d,]+ of ([\d,]+)"#, options: .regularExpression) {
            total = CatalogText.number(html[m].split(separator: " ").last!) ?? 0
        } else if html.contains("id=\"groupedRecord") {
            throw CatalogError.badResponse("results page without a result count")
        } else {
            total = 0
        }
        var searchId: String?
        if let r = html.range(of: #"searchId=\d+"#, options: .regularExpression) {
            searchId = String(html[r].dropFirst("searchId=".count))
        }
        let items = try resultFragments(html).compactMap(parseResult)
        return CatalogPage(items: items, total: total, page: page, searchId: searchId)
    }

    /// One fragment per `<div id="groupedRecord…">`, ending where the next result (or the page footer) starts.
    static func resultFragments(_ html: String) -> [String] {
        let marker = "<div id=\"groupedRecord"
        var parts = html.components(separatedBy: marker).dropFirst().map { marker + $0 }
        if let last = parts.indices.last {
            for end in ["id=\"searchResultsFooter\"", "class=\"search_tools", "id=\"pager", "class=\"pagination"] {
                if let r = parts[last].range(of: end) { parts[last] = String(parts[last][..<r.lowerBound]) }
            }
        }
        return parts
    }

    static func parseResult(_ fragment: String) throws -> CatalogItem? {
        let doc = try HTMLFragment(fragment)
        guard let root = doc.first("//div[starts-with(@id,'groupedRecord')]"),
              let id = root.attr("id")?.dropFirst("groupedRecord".count), !id.isEmpty else { return nil }
        return item(root, id: String(id))
    }

    /// A title's fields from its result markup (search results and list entries look the same).
    static func item(_ root: HTMLNode, id: String) -> CatalogItem {
        let titleLink = root.first(".//a[contains(@class,'result-title')]")
        let (title, subtitle) = splitTitle(titleLink?.text ?? "")
        var fields: [String: String] = [:]
        for label in root.all(".//div[contains(@class,'result-label')]") {
            guard let value = label.nextElement(withClass: "result-value") else { continue }
            let key = label.text
            if fields[key] == nil { fields[key] = value.text }
        }
        // The first manifestation is the format searched for; others (eMusic…) follow it.
        let manifestation = root.first(".//div[contains(concat(' ',normalize-space(@class),' '),' related-manifestation ')]")
        let status = manifestation?.first(".//div[contains(@class,'related-manifestation-shelf-status')]")
        let statusClass = status?.classes.first { $0.hasPrefix("status-") } ?? ""
        var shelf: String?, callNumber: String?, available: Int?
        if let details = manifestation?.first(".//div[contains(@class,'itemLocationDetails')]") {
            shelf = details.first(".//strong")?.text
            let lines = details.textLines.filter { $0 != shelf }
            for line in lines {
                if let r = line.range(of: #"^\d+ available"#, options: .regularExpression) {
                    available = Int(line[r].split(separator: " ")[0])
                } else if callNumber == nil {
                    callNumber = line
                }
            }
        }
        var recordId: String?
        if let action = manifestation?.first(".//a[starts-with(@id,'actionButton')]")?.attr("id") {
            recordId = String(action.dropFirst("actionButton".count))
        } else if let href = titleLink?.attr("href"), let r = href.range(of: #"/Record/\.?[a-z0-9]+"#, options: .regularExpression) {
            recordId = String(href[r].dropFirst("/Record/".count))
        }
        var variationId: String?
        if let onclick = manifestation?.first(".//a[contains(@onclick,'showRelatedManifestations')]")?.attr("onclick") {
            variationId = quotedArguments(onclick).last
        }
        let path = titleLink?.attr("href").map { String($0.split(separator: "?").first ?? "") }.flatMap { $0.isEmpty ? nil : $0 }
        return CatalogItem(
            id: id, title: title, subtitle: subtitle, author: fields["Author"].flatMap(nonEmpty),
            year: CatalogText.year(fields["Publication Date"]), language: fields["Language"].flatMap(nonEmpty),
            series: fields["Series"].flatMap(nonEmpty), recordId: recordId, variationId: variationId,
            statusText: status?.text ?? "", availability: CatalogAvailability(statusClass: statusClass),
            shelfLocation: shelf, callNumber: callNumber, availableCopies: available, pagePath: path)
    }

    /// "Hamilton: original Broadway cast recording" → ("Hamilton", "original Broadway cast recording").
    static func splitTitle(_ s: String) -> (String, String?) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: ": ") else { return (t, nil) }
        let sub = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return (String(t[..<r.lowerBound]), sub.isEmpty ? nil : sub)
    }

    /// The single-quoted arguments of an inline handler: "f('a','b', 'c')" → ["a", "b", "c"].
    static func quotedArguments(_ js: String) -> [String] {
        var out: [String] = []
        var current: String?
        for ch in js {
            if ch == "'" {
                if let c = current { out.append(c); current = nil } else { current = "" }
            } else if current != nil {
                current!.append(ch)
            }
        }
        return out
    }

    static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    // MARK: AJAX replies

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.badResponse("not a JSON object")
        }
        return o
    }

    /// "Where is it?": copies per shelf location across the network.
    public static func parseCopies(_ data: Data) throws -> [CatalogCopy] {
        let o = try jsonObject(data)
        guard let body = o["modalBody"] as? String else {
            throw CatalogError.badResponse((o["error"] as? String) ?? (o["message"] as? String) ?? "no copy details")
        }
        let doc = try HTMLFragment(body)
        return doc.all("//tr[td]").compactMap { row in
            let cells = row.all("./td")
            guard cells.count >= 2 else { return nil }
            let counts = cells[0].text
            var available = 0, total = 0
            if let r = counts.range(of: #"\d+ of \d+"#, options: .regularExpression) {
                let n = counts[r].split(separator: " ")
                available = Int(n[0]) ?? 0
                total = Int(n[2]) ?? 0
            } else {
                available = row.classes.contains("available") ? 1 : 0
                total = 1
            }
            let location = cells[1].text
            let library = location.components(separatedBy: " - ").first ?? location
            return CatalogCopy(library: library, location: location, callNumber: cells.count > 2 ? cells[2].text : "",
                               available: available, total: total)
        }
    }

    /// "Show Editions": one row per edition with its publication, status and UPC.
    public static func parseEditions(_ data: Data) throws -> [CatalogEdition] {
        let o = try jsonObject(data)
        guard let body = o["body"] as? String else { throw CatalogError.badResponse("no editions") }
        let marker = "<div class=\"relatedRecord"
        return try body.components(separatedBy: marker).dropFirst().compactMap { part in
            let doc = try HTMLFragment(marker + part)
            guard let root = doc.first("//div[contains(@class,'relatedRecord')]") else { return nil }
            var fields: [String: String] = [:]
            for label in root.all(".//div[contains(@class,'result-label')]") {
                if let value = label.nextElement(withClass: "result-value") { fields[label.text] = value.text }
            }
            let recordHref = root.first(".//a[starts-with(@href,'/Record/')]")?.attr("href") ?? ""
            let recordId = recordHref.dropFirst("/Record/".count).split(separator: "?").first.map(String.init) ?? ""
            guard !recordId.isEmpty else { return nil }
            var upc: String?
            if let src = root.first(".//img")?.attr("src"), let r = src.range(of: #"upc=\d+"#, options: .regularExpression) {
                upc = String(src[r].dropFirst(4))
            }
            let published = fields["Published"].flatMap(nonEmpty)
            var publisher = published
            if let p = published, let r = p.range(of: #"^\[?[cp]?\d{4}\]?\.?\s*"#, options: .regularExpression) {
                publisher = nonEmpty(String(p[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.")))
            }
            let status = root.first(".//div[contains(@class,'related-manifestation-shelf-status')]")
            return CatalogEdition(
                recordId: recordId, published: published, year: CatalogText.year(published), publisher: publisher,
                edition: fields["Edition"].flatMap(nonEmpty), physical: fields["Physical Description"].flatMap(nonEmpty),
                upc: upc, statusText: status?.text ?? "",
                availability: CatalogAvailability(statusClass: status?.classes.first { $0.hasPrefix("status-") } ?? ""))
        }
    }

    /// Every library in the network that owns a matching title, from the Location facet's "more…" popup.
    public static func parseLibraryFacet(_ data: Data) throws -> [CatalogLibrary] {
        let o = try jsonObject(data)
        guard let body = o["modalBody"] as? String else { throw CatalogError.badResponse("no locations") }
        let doc = try HTMLFragment(body)
        return doc.all("//label[input[contains(@value,'owning_location:')]]").compactMap { label in
            guard let value = label.first("./input")?.attr("value"),
                  let open = value.firstIndex(of: "\""), let close = value.lastIndex(of: "\""), open < close else { return nil }
            let raw = String(value[value.index(after: open)..<close])
            let name = raw.removingPercentEncoding ?? raw
            var count: Int?
            let text = label.text
            if let r = text.range(of: #"\(([\d,]+)\)$"#, options: .regularExpression) {
                count = CatalogText.number(text[r].dropFirst().dropLast())
            }
            return CatalogLibrary(name: name, count: count)
        }
    }

    // MARK: Work page

    public static func parseWork(_ html: String) throws -> CatalogWorkDetails {
        var details = CatalogWorkDetails()
        if let section = slice(html, from: "id=\"moreDetailsPanel", to: "id=\"subjectsPanel") ?? slice(html, from: "id=\"moreDetailsPanel", to: "id=\"tableOfContentsPanel") {
            let doc = try HTMLFragment("<div " + section)
            for label in doc.all("//div[contains(@class,'result-label')]") {
                guard let value = label.nextElement(withClass: "result-value") else { continue }
                switch label.text {
                case "UPC": details.upcs = value.textLines.filter { $0.allSatisfy(\.isNumber) }
                case "Contributors":
                    details.contributors = value.all("./a[contains(@href,'/Author/')]").map { a in
                        let role = a.followingText.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{a0}")))
                        return .init(name: a.text, role: role.isEmpty ? nil : role)
                    }
                default: break
                }
            }
        }
        if let section = slice(html, from: "id=\"subjectsPanelBody", to: "<div class=\"panel ") {
            let doc = try HTMLFragment("<div " + section)
            details.subjects = doc.all("//a[contains(@href,'searchIndex=Subject')]").map(\.text).filter { !$0.isEmpty }
        }
        if let section = slice(html, from: "id=\"tableOfContentsPlaceholder", to: "<div class=\"panel ") {
            let doc = try HTMLFragment("<div " + section)
            var current: CatalogWorkDetails.Contents?
            for node in doc.all("//h4 | //div[contains(@class,'col-xs-12') and not(h4)]") {
                if node.name == "h4" {
                    if let c = current, !c.tracks.isEmpty { details.contents.append(c) }
                    current = .init(heading: node.text, tracks: [])
                } else if !node.text.isEmpty {
                    if current == nil { current = .init(heading: nil, tracks: []) }
                    current!.tracks.append(node.text)
                }
            }
            if let c = current, !c.tracks.isEmpty { details.contents.append(c) }
        }
        return details
    }

    /// The markup cut at every match of `pattern` (an opening tag), each piece running to the next match.
    static func fragments(_ html: String, startingAt pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let starts = regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { Range($0.range, in: html)?.lowerBound }
        return starts.enumerated().map { i, start in
            String(html[start..<(i + 1 < starts.count ? starts[i + 1] : html.endIndex)])
        }
    }

    /// The markup between two markers (the first marker's own tag starts just before it).
    static func slice(_ s: String, from start: String, to end: String) -> String? {
        guard let a = s.range(of: start) else { return nil }
        let rest = s[a.lowerBound...]
        let stop = rest.dropFirst(start.count).range(of: end)?.lowerBound ?? rest.endIndex
        return String(rest[..<stop])
    }

    // MARK: Lists

    /// The patron's lists, from the "Add to List" form (`getSaveToListForm`).
    public static func parseUserLists(_ data: Data) throws -> [CatalogUserList] {
        let o = try jsonObject(data)
        guard let body = o["modalBody"] as? String else {
            if o["success"] as? Bool == false { throw CatalogError.notSignedIn }
            throw CatalogError.badResponse("no lists")
        }
        let doc = try HTMLFragment(body)
        return doc.all("//select[@id='addToList-list']/option").compactMap { option in
            guard let id = option.attr("value"), !id.isEmpty else { return nil }
            return CatalogUserList(id: id, title: option.text)
        }
    }

    /// One page of a list (`/MyAccount/MyList/<id>`): its entries and how many there are in all.
    public static func parseList(_ html: String, page: Int = 1) throws -> CatalogListPage {
        var total = 0
        if let m = html.range(of: #"Showing [\d,]+ - [\d,]+ of ([\d,]+)"#, options: .regularExpression) {
            total = CatalogText.number(html[m].split(separator: " ")[5]) ?? 0
        }
        let entries: [CatalogListEntry] = try fragments(html, startingAt: #"<div[^>]*\bid="listEntry\d+""#).compactMap { part in
            guard let entryRange = part.range(of: #"listEntry\d+"#, options: .regularExpression) else { return nil }
            let entryId = String(part[entryRange].dropFirst("listEntry".count))
            // The work ID is in the entry's own "Add to List" button (titles link to their records).
            var workId: String?
            for pattern in [#"'GroupedWork', '([0-9a-f-]+-[a-z]{3})'"#, #"/GroupedWork/([0-9a-f-]+-[a-z]{3})"#] {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let m = regex.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)),
                   let r = Range(m.range(at: 1), in: part) {
                    workId = String(part[r])
                    break
                }
            }
            guard let workId else { return nil }
            let doc = try HTMLFragment(part)
            guard let root = doc.first("//div[starts-with(@id,'listEntry')]") else { return nil }
            return CatalogListEntry(entryId: entryId, item: item(root, id: workId))
        }
        if total == 0 { total = entries.count }
        return CatalogListPage(entries: entries, total: total, page: page)
    }

    /// The reply to `saveToList`: its message, or why the title couldn't be added.
    public static func parseSaveToList(_ data: Data) throws -> String {
        let o = try jsonObject(data)
        let message = (o["message"] as? String).map { HTMLFragment.plainText($0) } ?? ""
        guard o["success"] as? Bool == true else {
            throw CatalogError.badResponse(message.isEmpty ? "the title wasn't added to the list" : message)
        }
        return message
    }

    // MARK: Account

    /// The reply to `/AJAX/JSON?method=loginUser`: the patron's name, or why sign-in failed.
    public static func parseLogin(_ data: Data) throws -> String {
        let o = try jsonObject(data)
        // Replies are wrapped in "result", except for some server errors.
        let result = o["result"] as? [String: Any] ?? o
        guard result["success"] != nil || result["message"] != nil else { throw CatalogError.badResponse("no sign-in result") }
        if result["success"] as? Bool == true { return (result["name"] as? String).flatMap(nonEmpty) ?? "Signed in" }
        if result["has2FA"] as? Bool == true || result["enroll2FA"] as? Bool == true {
            throw CatalogError.signIn("This account uses two-factor sign-in, which the app doesn't support.")
        }
        if result["passwordExpired"] as? Bool == true {
            throw CatalogError.signIn("The library says your PIN or password has expired. Reset it on the library's website.")
        }
        let message = (result["message"] as? String).map { HTMLFragment.plainText($0) }.flatMap(nonEmpty)
        throw CatalogError.signIn(message ?? "Sign-in failed. Check your library card number and PIN or password.")
    }

    /// The patron's checkouts (`getCheckouts`). Throws `notSignedIn` when the session has ended.
    public static func parseCheckouts(_ data: Data) throws -> [CatalogCheckout] {
        let o = try jsonObject(data)
        guard o["success"] as? Bool == true, let html = o["checkouts"] as? String else {
            let message = (o["message"] as? String).map { HTMLFragment.plainText($0) } ?? ""
            if message.lowercased().contains("log") || message.lowercased().contains("sign") || o["success"] as? Bool == false {
                throw CatalogError.notSignedIn
            }
            throw CatalogError.badResponse("no checkouts")
        }
        return try fragments(html, startingAt: #"<div[^>]*\bclass="result row"#).compactMap { part in
            let doc = try HTMLFragment(part)
            guard let link = doc.first("//a[contains(@class,'result-title')]") else { return nil }
            let (title, subtitle) = splitTitle(link.text)
            var fields: [String: String] = [:]
            for label in doc.all("//div[contains(@class,'result-label')]") {
                if let value = label.nextElement(withClass: "result-value") { fields[label.text] = value.text }
            }
            let href = link.attr("href") ?? ""
            let recordId = href.range(of: #"/Record/[^?/]+"#, options: .regularExpression).map { String(href[$0].dropFirst("/Record/".count)) }
            var cover = doc.first("//img")?.attr("src")
            if let c = cover, let r = c.range(of: "/bookcover.php") { cover = String(c[r.lowerBound...]) }
            return CatalogCheckout(title: title, subtitle: subtitle, author: fields["Author"].flatMap(nonEmpty),
                                   format: fields["Format"].flatMap(nonEmpty), callNumber: fields["Call Number"].flatMap(nonEmpty),
                                   due: fields["Due"].flatMap(nonEmpty), renewed: fields["Renewed"].flatMap(nonEmpty),
                                   recordId: recordId, coverPath: cover)
        }
    }
}

// MARK: HTML fragments

/// A small XPath wrapper over Foundation's tidy-HTML parser.
struct HTMLFragment {
    let document: XMLDocument

    init(_ html: String) throws {
        do {
            document = try XMLDocument(xmlString: "<html><body>\(html)</body></html>",
                                       options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        } catch {
            throw CatalogError.badResponse("unreadable HTML")
        }
    }

    func first(_ xpath: String) -> HTMLNode? { all(xpath).first }

    func all(_ xpath: String) -> [HTMLNode] {
        ((try? document.nodes(forXPath: xpath)) ?? []).compactMap { $0 as? XMLElement }.map(HTMLNode.init)
    }

    /// Markup reduced to its text.
    static func plainText(_ html: String) -> String {
        guard html.contains("<") || html.contains("&"), let doc = try? HTMLFragment(html) else { return html.trimmingCharacters(in: .whitespacesAndNewlines) }
        return HTMLNode.clean(doc.document.rootElement()?.stringValue ?? "")
    }
}

struct HTMLNode {
    let element: XMLElement

    var name: String { element.name ?? "" }
    func attr(_ name: String) -> String? { element.attribute(forName: name)?.stringValue }
    var classes: [String] { (attr("class") ?? "").split(separator: " ").map(String.init) }

    /// The text with whitespace (and non-breaking spaces) collapsed.
    var text: String { Self.clean(element.stringValue ?? "") }

    /// Text split at `<br>`s and block children: "Natick - Audiovisual", "[CD] Rock / Dro", "1 available".
    var textLines: [String] {
        var lines: [String] = []
        var current = ""
        func flush() {
            let t = Self.clean(current)
            if !t.isEmpty { lines.append(t) }
            current = ""
        }
        func walk(_ node: XMLNode) {
            if node.kind == .text { current += node.stringValue ?? ""; return }
            guard let e = node as? XMLElement else { return }
            let block = ["br", "div", "p", "li", "tr", "h1", "h2", "h3", "h4", "strong"].contains(e.name ?? "")
            if block { flush() }
            for c in e.children ?? [] { walk(c) }
            if block { flush() }
        }
        for c in element.children ?? [] { walk(c) }
        flush()
        return lines
    }

    /// The text right after this element, up to the next element ("&nbsp;Performer" after a contributor link).
    var followingText: String {
        var s = ""
        var node = element.nextSibling
        while let n = node, n.kind == .text {
            s += n.stringValue ?? ""
            node = n.nextSibling
        }
        return Self.clean(s)
    }

    func first(_ xpath: String) -> HTMLNode? { all(xpath).first }

    func all(_ xpath: String) -> [HTMLNode] {
        ((try? element.nodes(forXPath: xpath)) ?? []).compactMap { $0 as? XMLElement }.map(HTMLNode.init)
    }

    /// The next sibling element with this class (a label's value).
    func nextElement(withClass cls: String) -> HTMLNode? {
        var node = element.nextSibling
        while let n = node {
            if let e = n as? XMLElement {
                let node = HTMLNode(element: e)
                return node.classes.contains(cls) ? node : nil
            }
            node = n.nextSibling
        }
        return nil
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{a0}", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
#endif
