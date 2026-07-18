import Foundation

/// A single user-configured RSS/Atom feed.
///
/// Replaces the old plain `[String]` URL blob with a richer, per-feed model so
/// each feed can carry a custom display name, be individually enabled/disabled,
/// reordered, and deleted. Persisted as JSON under `glancekit.feeds.sources`;
/// the legacy `glancekit.feeds.urls` key is kept in sync for backwards
/// compatibility (see `FeedsPlugin.persistSources`).
struct FeedSource: Identifiable, Codable, Hashable {
    let id: UUID
    /// Raw feed URL string as the user typed / we normalized it.
    var url: String
    /// User-chosen display name; `nil` means "fall back to the feed's own
    /// <title>, or its host". Auto-filled from the feed title on first fetch.
    var name: String?
    /// A configured-but-off feed stays in the list but isn't fetched.
    var enabled: Bool

    init(id: UUID = UUID(), url: String, name: String? = nil, enabled: Bool = true) {
        self.id = id
        self.url = url
        self.name = name
        self.enabled = enabled
    }

    /// Host of the URL, when it parses to one — used as a display fallback.
    var host: String? {
        URL(string: url)?.host
    }

    /// Best label to show for this feed: custom name, else host, else raw URL.
    var displayName: String {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        return host ?? url
    }
}
