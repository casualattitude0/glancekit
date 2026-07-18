import SwiftUI
import Observation
import AppKit

/// News-reader glance: merges user-configured RSS/Atom feeds with the Hacker
/// News front page into a single unread-tracking reading list.
///
/// - Sources: a persisted list of feed URLs (RSS 2.0 or Atom) plus a built-in
///   Hacker News toggle. All enabled sources are fetched concurrently; one
///   broken feed never sinks the batch — it's skipped and the rest continue.
/// - Unread: item ids not present in the persisted "seen" set are unread. The
///   popover surfaces the count and can mark everything read.
@MainActor
@Observable
final class FeedsPlugin: GlancePlugin {
    nonisolated var id: String { "feeds" }
    nonisolated var title: String { "Feeds" }
    nonisolated var iconSystemName: String { "newspaper" }
    var refreshInterval: TimeInterval { 600 }

    var preferredToolWindowSize: CGSize? { CGSize(width: 380, height: 520) }

    // MARK: Persisted preferences

    /// User-configured RSS/Atom feed URLs.
    var feedURLs: [String] {
        didSet { UserDefaults.standard.set(feedURLs, forKey: Keys.feeds) }
    }

    /// Whether the built-in Hacker News front page source is enabled.
    var hackerNewsEnabled: Bool {
        didSet { UserDefaults.standard.set(hackerNewsEnabled, forKey: Keys.hn) }
    }

    /// Max merged items to keep after sorting.
    var maxItems: Int {
        didSet { UserDefaults.standard.set(maxItems, forKey: Keys.maxItems) }
    }

    /// Persisted set of item ids the user has already seen.
    private var seenIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(seenIDs), forKey: Keys.seen) }
    }

    // MARK: Runtime state

    private(set) var items: [FeedItem] = []
    private(set) var lastError: String?

    private enum Keys {
        static let feeds = "glancekit.feeds.urls"
        static let hn = "glancekit.feeds.hackernews"
        static let maxItems = "glancekit.feeds.maxItems"
        static let seen = "glancekit.feeds.seen"
    }

    private static let defaultFeed = "https://daringfireball.net/feeds/main"

    init() {
        let d = UserDefaults.standard
        feedURLs = d.stringArray(forKey: Keys.feeds) ?? [FeedsPlugin.defaultFeed]
        hackerNewsEnabled = d.object(forKey: Keys.hn) as? Bool ?? true
        let storedMax = d.integer(forKey: Keys.maxItems)
        maxItems = storedMax > 0 ? storedMax : 40
        seenIDs = Set(d.stringArray(forKey: Keys.seen) ?? [])
    }

    // MARK: Derived

    var unreadItems: [FeedItem] { items.filter { !seenIDs.contains($0.id) } }
    var unreadCount: Int { unreadItems.count }
    func isUnread(_ item: FeedItem) -> Bool { !seenIDs.contains(item.id) }

    /// Mark every currently-loaded item as seen.
    func markAllRead() {
        seenIDs.formUnion(items.map(\.id))
    }

    /// Open an item's URL in the default browser.
    func open(_ item: FeedItem) {
        guard let url = URL(string: item.url) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: GlancePlugin

    func refresh() async {
        let client = NetworkClient()
        var errors: [String] = []

        // Fetch every enabled source concurrently.
        let fetched: [[FeedItem]] = await withTaskGroup(of: FetchOutcome.self) { group in
            if hackerNewsEnabled {
                group.addTask { await FeedsPlugin.fetchHackerNews(client: client) }
            }
            for raw in feedURLs {
                let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { continue }
                group.addTask { await FeedsPlugin.fetchFeed(url, client: client) }
            }
            var out: [[FeedItem]] = []
            for await result in group {
                switch result {
                case .items(let items): out.append(items)
                case .failed(let message): errors.append(message)
                }
            }
            return out
        }

        // Merge, dedup by url-or-guid, sort most-recent-first, cap.
        var merged: [FeedItem] = []
        var seenKeys = Set<String>()
        for item in fetched.flatMap({ $0 }) {
            let key = item.url.isEmpty ? item.id : item.url
            if seenKeys.insert(key).inserted { merged.append(item) }
        }
        merged.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if merged.count > maxItems { merged = Array(merged.prefix(maxItems)) }

        items = merged
        // Only surface an error when nothing at all came back; a single broken
        // feed among several shouldn't nag.
        if merged.isEmpty && !errors.isEmpty {
            lastError = errors.first
        } else {
            lastError = nil
        }
    }

    func currentSignal() -> GlanceSignal? {
        let unread = unreadItems
        guard let latest = unread.first else { return nil }
        let count = unread.count
        let truncated = FeedsPlugin.truncate(latest.title, to: 48)
        let headline = "\(count) new · \(truncated)"
        let priority: GlanceSignal.Priority = count >= 5 ? .normal : .ambient
        return GlanceSignal(
            priority: priority,
            score: Double(count),
            headline: headline,
            detail: latest.sourceName,
            systemImage: iconSystemName
        )
    }

    func popoverSection() -> AnyView { AnyView(FeedsPopover(plugin: self)) }
    func settingsSection() -> AnyView { AnyView(FeedsSettings(plugin: self)) }

    // MARK: Fetching

    /// Result of fetching one source: either its items or a human-readable error.
    /// (A dedicated type because `Result`'s `Failure` must be an `Error`.)
    private enum FetchOutcome: Sendable {
        case items([FeedItem])
        case failed(String)
    }

    private static func fetchFeed(_ urlString: String, client: NetworkClient) async -> FetchOutcome {
        do {
            let data = try await client.data(from: urlString)
            guard let parsed = FeedXMLParser.parse(data, fallbackName: hostName(urlString)) else {
                return .failed("Could not parse \(hostName(urlString))")
            }
            return .items(parsed.items)
        } catch {
            return .failed("\(hostName(urlString)): \(error.localizedDescription)")
        }
    }

    private static func fetchHackerNews(client: NetworkClient) async -> FetchOutcome {
        do {
            let response = try await client.get(
                HNResponse.self,
                from: "https://hn.algolia.com/api/v1/search?tags=front_page"
            )
            let items: [FeedItem] = response.hits.compactMap { hit in
                let title = hit.title ?? "(untitled)"
                let hnItemURL = "https://news.ycombinator.com/item?id=\(hit.objectID)"
                let url = (hit.url?.isEmpty == false) ? hit.url! : hnItemURL
                let date = hit.created_at_i.map { Date(timeIntervalSince1970: $0) }
                return FeedItem(id: "hn-\(hit.objectID)", title: title,
                                sourceName: "Hacker News", url: url, date: date)
            }
            return .items(items)
        } catch {
            return .failed("Hacker News: \(error.localizedDescription)")
        }
    }

    private struct HNResponse: Decodable { let hits: [HNHit] }
    private struct HNHit: Decodable {
        let objectID: String
        let title: String?
        let url: String?
        let points: Int?
        let num_comments: Int?
        let created_at_i: Double?
    }

    // MARK: Small helpers

    private static func hostName(_ urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }

    static func truncate(_ s: String, to n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Popover UI

private struct FeedsPopover: View {
    @Bindable var plugin: FeedsPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                let unread = plugin.unreadCount
                Text(unread > 0 ? "\(unread) unread" : "All caught up")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if unread > 0 {
                    Button("Mark all read") { plugin.markAllRead() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if plugin.items.isEmpty {
                Text("No articles yet…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(plugin.items) { item in
                            FeedsRow(item: item, unread: plugin.isUnread(item)) {
                                plugin.open(item)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .onAppear { plugin.markAllRead() }
    }
}

private struct FeedsRow: View {
    let item: FeedItem
    let unread: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(unread ? Color.accentColor : Color.clear)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(unread ? .callout.weight(.semibold) : .callout)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        if let date = item.date {
            return "\(item.sourceName) · \(FeedsRow.relative.localizedString(for: date, relativeTo: Date()))"
        }
        return item.sourceName
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - Settings UI

private struct FeedsSettings: View {
    @Bindable var plugin: FeedsPlugin
    @State private var urlsText: String = ""
    @State private var savedNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Feed URLs")
                .font(.headline)
            Text("One RSS or Atom feed URL per line (commas also accepted).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("https://example.com/feed.xml", text: $urlsText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
            HStack {
                Button("Save feeds") {
                    plugin.feedURLs = urlsText
                        .split(whereSeparator: { $0 == "\n" || $0 == "," })
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    savedNote = "Saved."
                    Task { await plugin.refresh() }
                }
                if let note = savedNote {
                    Text(note).font(.caption).foregroundStyle(.green)
                }
            }

            Divider()

            Toggle("Include Hacker News front page", isOn: $plugin.hackerNewsEnabled)
                .onChange(of: plugin.hackerNewsEnabled) { _, _ in
                    Task { await plugin.refresh() }
                }

            Stepper(value: $plugin.maxItems, in: 10...100, step: 10) {
                Text("Max items: \(plugin.maxItems)")
            }
        }
        .onAppear {
            urlsText = plugin.feedURLs.joined(separator: "\n")
        }
    }
}
