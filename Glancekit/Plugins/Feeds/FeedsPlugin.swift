import SwiftUI
import Observation
import AppKit

/// News-reader glance: merges user-configured RSS/Atom feeds with the Hacker
/// News front page into a single unread-tracking reading list.
///
/// - Sources: a persisted list of `FeedSource`s (RSS 2.0 or Atom), each with an
///   optional custom name and an individual enabled flag, plus a built-in
///   Hacker News toggle. All enabled sources are fetched concurrently; one
///   broken feed never sinks the batch — it's skipped and the rest continue.
/// - Unread: item ids not present in the persisted "seen" set are unread. The
///   popover surfaces per-source counts and can mark items read individually or
///   all at once.
@MainActor
@Observable
final class FeedsPlugin: GlancePlugin {
    nonisolated var id: String { "feeds" }
    nonisolated var title: String { "Feeds" }
    nonisolated var iconSystemName: String { "newspaper" }
    var refreshInterval: TimeInterval { 600 }

    var preferredToolWindowSize: CGSize? { CGSize(width: 380, height: 520) }

    // MARK: Persisted preferences

    /// User-configured feeds (URL + optional name + enabled). Persisted as JSON.
    var feedSources: [FeedSource] {
        didSet { persistSources() }
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
    private(set) var isRefreshing = false

    /// Hard cap on the persisted seen-set so it can't grow without bound as old
    /// articles scroll off the merged list forever.
    private static let seenCap = 1000

    private enum Keys {
        static let feeds = "glancekit.feeds.urls"        // legacy [String], kept in sync
        static let sources = "glancekit.feeds.sources"   // new JSON [FeedSource]
        static let hn = "glancekit.feeds.hackernews"
        static let maxItems = "glancekit.feeds.maxItems"
        static let seen = "glancekit.feeds.seen"
    }

    private static let defaultFeed = "https://daringfireball.net/feeds/main"

    init() {
        let d = UserDefaults.standard

        // Prefer the new per-feed model; otherwise migrate the legacy URL list
        // (or seed the default feed for a brand-new install) so no feed is lost.
        if let data = d.data(forKey: Keys.sources),
           let decoded = try? JSONDecoder().decode([FeedSource].self, from: data) {
            feedSources = decoded
        } else {
            let legacy = d.stringArray(forKey: Keys.feeds) ?? [FeedsPlugin.defaultFeed]
            feedSources = legacy
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { FeedSource(url: $0) }
        }

        hackerNewsEnabled = d.object(forKey: Keys.hn) as? Bool ?? true
        let storedMax = d.integer(forKey: Keys.maxItems)
        maxItems = storedMax > 0 ? storedMax : 40
        seenIDs = Set(d.stringArray(forKey: Keys.seen) ?? [])
    }

    private func persistSources() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(feedSources) {
            d.set(data, forKey: Keys.sources)
        }
        // Keep the legacy key in sync so any older reader still sees the URLs.
        d.set(feedSources.map(\.url), forKey: Keys.feeds)
    }

    // MARK: Derived

    var unreadItems: [FeedItem] { items.filter { !seenIDs.contains($0.id) } }
    var unreadCount: Int { unreadItems.count }
    func isUnread(_ item: FeedItem) -> Bool { !seenIDs.contains(item.id) }

    /// Distinct source names present in the current items, in first-seen order.
    var presentSources: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for item in items where seen.insert(item.sourceName).inserted {
            order.append(item.sourceName)
        }
        return order
    }

    /// Unread count for one source name.
    func unreadCount(forSource source: String) -> Int {
        items.filter { $0.sourceName == source && !seenIDs.contains($0.id) }.count
    }

    // MARK: Read/unread mutations

    /// Mark every currently-loaded item as seen.
    func markAllRead() {
        seenIDs.formUnion(items.map(\.id))
        capSeenIDs()
    }

    func markRead(_ item: FeedItem) {
        guard !seenIDs.contains(item.id) else { return }
        seenIDs.insert(item.id)
        capSeenIDs()
    }

    func markUnread(_ item: FeedItem) {
        seenIDs.remove(item.id)
    }

    func toggleRead(_ item: FeedItem) {
        if seenIDs.contains(item.id) { markUnread(item) } else { markRead(item) }
    }

    /// Keep the persisted seen-set bounded: prefer ids still visible in the
    /// current list, then top up with other recent ids up to the cap.
    private func capSeenIDs() {
        guard seenIDs.count > FeedsPlugin.seenCap else { return }
        var kept = Set(items.map(\.id)).intersection(seenIDs)
        if kept.count < FeedsPlugin.seenCap {
            for anID in seenIDs where !kept.contains(anID) {
                kept.insert(anID)
                if kept.count >= FeedsPlugin.seenCap { break }
            }
        }
        seenIDs = kept
    }

    // MARK: Feed-list mutations

    /// Validate + add a feed. Returns an error message on failure, else `nil`.
    @discardableResult
    func addFeed(url rawURL: String, name rawName: String?) -> String? {
        var url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return "Enter a feed URL." }
        // Be forgiving: default to https:// when no scheme is given.
        if !url.contains("://") { url = "https://" + url }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https", parsed.host != nil else {
            return "That doesn't look like a valid http(s) URL."
        }
        if feedSources.contains(where: { $0.url.caseInsensitiveCompare(url) == .orderedSame }) {
            return "That feed is already in your list."
        }
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        feedSources.append(FeedSource(url: url, name: (name?.isEmpty == false) ? name : nil))
        return nil
    }

    func removeFeed(_ source: FeedSource) {
        feedSources.removeAll { $0.id == source.id }
    }

    func moveFeeds(from offsets: IndexSet, to destination: Int) {
        feedSources.move(fromOffsets: offsets, toOffset: destination)
    }

    func deleteFeeds(at offsets: IndexSet) {
        feedSources.remove(atOffsets: offsets)
    }

    // MARK: Item actions

    /// Open an item's URL in the default browser and mark it read.
    func open(_ item: FeedItem) {
        markRead(item)
        guard let url = URL(string: item.url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Copy an item's link to the general pasteboard.
    func copyLink(_ item: FeedItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.url, forType: .string)
    }

    // MARK: GlancePlugin

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let client = NetworkClient()
        let sources = feedSources.filter { $0.enabled }
        var errors: [String] = []
        var titleUpdates: [UUID: String] = [:]

        // Fetch every enabled source concurrently.
        let outcomes: [FetchOutcome] = await withTaskGroup(of: FetchOutcome.self) { group in
            if hackerNewsEnabled {
                group.addTask { await FeedsPlugin.fetchHackerNews(client: client) }
            }
            for source in sources {
                let url = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { continue }
                let sid = source.id
                group.addTask { await FeedsPlugin.fetchFeed(url, sourceID: sid, client: client) }
            }
            var out: [FetchOutcome] = []
            for await result in group { out.append(result) }
            return out
        }

        var lists: [[FeedItem]] = []
        for outcome in outcomes {
            switch outcome {
            case .items(let fetched, let sourceID, let discoveredTitle):
                lists.append(fetched)
                if let sourceID, let discoveredTitle, !discoveredTitle.isEmpty {
                    titleUpdates[sourceID] = discoveredTitle
                }
            case .failed(let message):
                errors.append(message)
            }
        }

        // Merge, dedup by url-or-guid, sort most-recent-first, cap.
        var merged: [FeedItem] = []
        var seenKeys = Set<String>()
        for item in lists.flatMap({ $0 }) {
            let key = item.url.isEmpty ? item.id : item.url
            if seenKeys.insert(key).inserted { merged.append(item) }
        }
        merged.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if merged.count > maxItems { merged = Array(merged.prefix(maxItems)) }

        items = merged
        capSeenIDs()
        applyDiscoveredTitles(titleUpdates)

        // Only surface an error when nothing at all came back; a single broken
        // feed among several shouldn't nag.
        if merged.isEmpty && !errors.isEmpty {
            lastError = errors.first
        } else {
            lastError = nil
        }
    }

    /// Auto-fill each un-named feed's display name from the feed's own <title>.
    private func applyDiscoveredTitles(_ updates: [UUID: String]) {
        guard !updates.isEmpty else { return }
        var changed = false
        var sources = feedSources
        for i in sources.indices {
            let hasName = (sources[i].name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            if !hasName, let title = updates[sources[i].id],
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sources[i].name = title
                changed = true
            }
        }
        if changed { feedSources = sources }
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
        case items([FeedItem], sourceID: UUID?, discoveredTitle: String?)
        case failed(String)
    }

    private static func fetchFeed(_ urlString: String, sourceID: UUID, client: NetworkClient) async -> FetchOutcome {
        do {
            let data = try await client.data(from: urlString)
            guard let parsed = FeedXMLParser.parse(data, fallbackName: hostName(urlString)) else {
                return .failed("Could not parse \(hostName(urlString))")
            }
            return .items(parsed.items, sourceID: sourceID, discoveredTitle: parsed.feedTitle)
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
            return .items(items, sourceID: nil, discoveredTitle: nil)
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
    /// `nil` = show all sources; otherwise restrict to this source name.
    @State private var sourceFilter: String?

    private var visibleItems: [FeedItem] {
        // Fall back to "all" if the active filter's source has since disappeared.
        guard let filter = sourceFilter, plugin.presentSources.contains(filter) else {
            return plugin.items
        }
        return plugin.items.filter { $0.sourceName == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            header

            if !plugin.presentSources.isEmpty {
                sourceFilterBar
            }

            if plugin.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleItems) { item in
                            FeedsRow(item: item, unread: plugin.isUnread(item),
                                     onOpen: { plugin.open(item) },
                                     onToggleRead: { plugin.toggleRead(item) },
                                     onCopy: { plugin.copyLink(item) })
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
    }

    private var header: some View {
        HStack {
            let unread = plugin.unreadCount
            Text(unread > 0 ? "\(unread) unread" : "All caught up")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                Task { await plugin.refresh() }
            } label: {
                if plugin.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(plugin.isRefreshing)
            .help("Refresh now")

            if unread > 0 {
                Button("Mark all read") { plugin.markAllRead() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    private var sourceFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FeedsFilterChip(label: "All", count: plugin.unreadCount,
                                selected: sourceFilter == nil) {
                    sourceFilter = nil
                }
                ForEach(plugin.presentSources, id: \.self) { source in
                    FeedsFilterChip(label: source,
                                    count: plugin.unreadCount(forSource: source),
                                    selected: sourceFilter == source) {
                        sourceFilter = (sourceFilter == source) ? nil : source
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plugin.isRefreshing ? "Loading…" : "No articles yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !plugin.isRefreshing {
                Text("Add feeds in Settings, or check your connection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FeedsFilterChip: View {
    let label: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12))
            )
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct FeedsRow: View {
    let item: FeedItem
    let unread: Bool
    let onOpen: () -> Void
    let onToggleRead: () -> Void
    let onCopy: () -> Void

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
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Copy Link") { onCopy() }
            Button(unread ? "Mark as Read" : "Mark as Unread") { onToggleRead() }
        }
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
    @State private var newURL: String = ""
    @State private var newName: String = ""
    @State private var addError: String?

    var body: some View {
        SettingsPage("Feeds") {
            // Add-a-feed form.
            VStack(alignment: .leading, spacing: 6) {
                TextField("Feed URL (https://example.com/feed.xml)", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Display name (optional)", text: $newName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Add feed") { addFeed() }
                        .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let addError {
                        Text(addError).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            if plugin.feedSources.isEmpty {
                SettingsHelp("No feeds configured. Add one above.")
            } else {
                SettingsHelp("Drag to reorder. Toggle to enable/disable without removing.")
                List {
                    ForEach($plugin.feedSources) { $source in
                        FeedsSourceRow(source: $source) {
                            plugin.removeFeed(source)
                        }
                    }
                    .onMove { plugin.moveFeeds(from: $0, to: $1) }
                    .onDelete { plugin.deleteFeeds(at: $0) }
                }
                .frame(minHeight: 120, maxHeight: 220)
            }

            Divider()

            SettingsToggleRow("Include Hacker News front page", isOn: $plugin.hackerNewsEnabled)
                .onChange(of: plugin.hackerNewsEnabled) { _, _ in
                    Task { await plugin.refresh() }
                }

            Stepper(value: $plugin.maxItems, in: 10...100, step: 10) {
                Text("Max items: \(plugin.maxItems)")
            }
        }
    }

    private func addFeed() {
        if let error = plugin.addFeed(url: newURL, name: newName) {
            addError = error
            return
        }
        addError = nil
        newURL = ""
        newName = ""
        Task { await plugin.refresh() }
    }
}

private struct FeedsSourceRow: View {
    @Binding var source: FeedSource
    let onDelete: () -> Void

    private var nameBinding: Binding<String> {
        Binding(
            get: { source.name ?? "" },
            set: { source.name = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $source.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(source.enabled ? "Enabled" : "Disabled")

            VStack(alignment: .leading, spacing: 2) {
                TextField(source.host ?? "Name", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                Text(source.url)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .opacity(source.enabled ? 1 : 0.5)

            Spacer(minLength: 0)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove feed")
        }
        .padding(.vertical, 2)
    }
}
