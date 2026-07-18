import Foundation

/// A single parsed article from any source (RSS, Atom, or Hacker News).
struct FeedItem: Identifiable, Hashable {
    /// Stable identity: the item's guid/id when present, else its URL.
    let id: String
    let title: String
    /// Display name of the source this item came from.
    let sourceName: String
    let url: String
    /// Publication date, or `nil` when the source date was missing/unparseable.
    let date: Date?
}

/// A minimal, crash-proof `XMLParser` delegate that extracts items from BOTH
/// RSS 2.0 (`<item>` → title/link/pubDate/guid) and Atom (`<entry>` →
/// title/link href/updated|published/id) feeds.
///
/// Dates are parsed defensively: RFC822 for RSS, ISO8601 for Atom. When a date
/// can't be parsed the item is still kept with a `nil` date. A malformed document
/// simply yields whatever items were completed before the failure — the caller
/// treats a parse failure as "skip this feed" and moves on.
final class FeedXMLParser: NSObject, XMLParserDelegate {

    /// Parse `data` as an RSS/Atom feed. Returns the extracted items, or `nil`
    /// when the document is malformed enough that `XMLParser` reports an error.
    /// `sourceName` labels every produced item; `fallbackName` is used until a
    /// channel/feed `<title>` is discovered.
    static func parse(_ data: Data, fallbackName: String) -> (items: [FeedItem], feedTitle: String?)? {
        let delegate = FeedXMLParser(fallbackName: fallbackName)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return (delegate.items, delegate.feedTitle)
    }

    private let fallbackName: String
    private(set) var items: [FeedItem] = []
    private(set) var feedTitle: String?

    private init(fallbackName: String) {
        self.fallbackName = fallbackName
    }

    // Parser scratch state.
    private var elementPath: [String] = []
    private var text = ""

    private var inItem = false          // RSS <item> or Atom <entry>
    private var curTitle = ""
    private var curLink = ""
    private var curDate = ""
    private var curGuid = ""
    /// Whether the source uses the Atom item element name.
    private var itemIsAtomEntry = false

    // Date formatters (built once).
    private static let rfc822: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm Z",
        ]
        return formats.map { fmt in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "GMT")
            df.dateFormat = fmt
            return df
        }
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let d = iso8601.date(from: s) { return d }
        if let d = iso8601Fractional.date(from: s) { return d }
        for df in rfc822 { if let d = df.date(from: s) { return d } }
        return nil
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        elementPath.append(name)
        text = ""

        if name == "item" || name == "entry" {
            inItem = true
            itemIsAtomEntry = (name == "entry")
            curTitle = ""; curLink = ""; curDate = ""; curGuid = ""
        } else if inItem && itemIsAtomEntry && name == "link" {
            // Atom links carry the href in an attribute; prefer rel="alternate".
            let href = attributeDict["href"] ?? ""
            let rel = attributeDict["rel"] ?? "alternate"
            if !href.isEmpty, rel == "alternate" || curLink.isEmpty {
                curLink = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if name == "item" || name == "entry" {
            finishItem()
            inItem = false
        } else if inItem {
            switch name {
            case "title": if curTitle.isEmpty { curTitle = value }
            case "link": if !itemIsAtomEntry, !value.isEmpty { curLink = value }
            case "guid", "id": if curGuid.isEmpty { curGuid = value }
            case "pubdate", "published", "updated", "date":
                if curDate.isEmpty { curDate = value }
            default: break
            }
        } else {
            // Feed-level title (RSS channel title / Atom feed title). Only accept
            // a title that isn't nested inside an item/entry.
            if name == "title", feedTitle == nil, !value.isEmpty {
                let depth = elementPath.count
                // channel > title  OR  feed > title  (i.e. path length 3)
                if depth <= 3 { feedTitle = value }
            }
        }

        if !elementPath.isEmpty { elementPath.removeLast() }
        text = ""
    }

    private func finishItem() {
        let link = curLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let guid = curGuid.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = curTitle.isEmpty ? "(untitled)" : curTitle
        // Need at least a link or a guid to be a usable, dedup-able item.
        guard !link.isEmpty || !guid.isEmpty else { return }
        let identity = !guid.isEmpty ? guid : link
        items.append(FeedItem(
            id: identity,
            title: title,
            sourceName: feedTitle ?? fallbackName,
            url: link.isEmpty ? guid : link,
            date: FeedXMLParser.parseDate(curDate)
        ))
    }
}
