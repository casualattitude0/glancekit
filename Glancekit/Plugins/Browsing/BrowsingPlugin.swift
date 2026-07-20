import SwiftUI
import Observation
import AppKit

/// Browsing History glance — the Clipboard glance's shape, applied to URLs.
///
/// Every `refresh()` tick asks the frontmost browser what its active tab is and
/// records new pages into a persisted ring buffer. The popover is a searchable
/// list; clicking a row reopens the page. Pinned entries survive the size cap
/// and sort to the top. See `BrowsingSources.swift` for the two capture
/// mechanisms (Apple Events for Safari/Chromium, `places.sqlite` for Firefox).
///
/// PRIVACY. Browsing history is more sensitive than a clipboard, so the defaults
/// lean shut and the escape hatches are the same ones Clipboard offers plus two:
///
/// - Only the **frontmost** browser is ever queried. A background window you
///   aren't looking at is not recorded, and no event is sent to a browser that
///   isn't already running.
/// - Incognito/private windows are skipped by default — reliably for Chromium
///   browsers, which report window `mode`. **Safari exposes no private-window
///   property to AppleScript**, so private Safari tabs cannot be distinguished
///   and *are* recorded; the blocklist and the pause controls are the remedy.
/// - A domain blocklist suppresses matching hosts entirely.
/// - Only `http`/`https` is recorded — never `file:`, `about:`, or extension URLs.
/// - Nothing here is a secret, so all prefs live in plain `UserDefaults`.
@MainActor
@Observable
final class BrowsingPlugin: GlancePlugin {
    nonisolated var id: String { "browsing" }
    nonisolated var title: String { "Browsing" }
    nonisolated var iconSystemName: String { "safari" }

    /// One second, matching Clipboard. Anything slower loses pages outright:
    /// clicking through a site at reading speed leaves many pages on screen for
    /// less than one tick, and a page that is never sampled can never be
    /// recorded. Redirect noise is handled after the fact in `observe(_:)`
    /// rather than by polling slowly.
    var refreshInterval: TimeInterval { 1 }

    var preferredToolWindowSize: CGSize? { CGSize(width: 380, height: 480) }
    var fillsToolWindow: Bool { true }

    // MARK: Entry model

    struct Entry: Identifiable, Codable, Equatable {
        var id: UUID
        var url: String
        var title: String
        var browser: Browser
        /// Most recent visit. Drives sort order and the relative timestamp.
        var timestamp: Date
        /// How many separate times this URL has come back to the front tab.
        var visits: Int
        var pinned: Bool

        init(id: UUID = UUID(), url: String, title: String, browser: Browser,
             timestamp: Date = Date(), visits: Int = 1, pinned: Bool = false) {
            self.id = id
            self.url = url
            self.title = title
            self.browser = browser
            self.timestamp = timestamp
            self.visits = visits
            self.pinned = pinned
        }

        /// Host without a leading `www.`, for display and blocklist matching.
        var host: String {
            guard let h = URL(string: url)?.host else { return "" }
            return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }

        /// What the row leads with: the page title when there is one, else the
        /// URL. Plenty of pages report an empty title while still loading.
        var displayTitle: String {
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url : title
        }
    }

    // MARK: Persisted state

    private(set) var entries: [Entry] = []

    /// Max number of *unpinned* entries kept. Pinned entries don't count. The
    /// settings Stepper is bounded 25...500; never self-assign here (didSet would
    /// re-enter), so we clamp on read from storage in `init` instead.
    var maxEntries: Int {
        didSet {
            UserDefaults.standard.set(maxEntries, forKey: maxEntriesKey)
            trim()
            persist()
        }
    }

    /// When true, refresh() polls nothing at all.
    var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: pausedKey) }
    }

    /// Capturing is suspended until this moment (a timed pause). `nil` = no timed
    /// pause. Expired values are cleared lazily in `refresh()`. Distinct from the
    /// indefinite `isPaused`.
    var pausedUntil: Date? {
        didSet {
            if let until = pausedUntil {
                UserDefaults.standard.set(until.timeIntervalSinceReferenceDate, forKey: pausedUntilKey)
            } else {
                UserDefaults.standard.removeObject(forKey: pausedUntilKey)
            }
        }
    }

    /// When true, all unpinned history is wiped when the app terminates.
    var clearOnQuit: Bool {
        didSet { UserDefaults.standard.set(clearOnQuit, forKey: clearOnQuitKey) }
    }

    /// Which browsers to watch. Empty by default — the glance records nothing
    /// until the user opts a browser in, which is also what makes the Automation
    /// prompt an explicit, understood action rather than a surprise.
    var enabledBrowsers: Set<Browser> {
        didSet {
            UserDefaults.standard.set(enabledBrowsers.map(\.rawValue), forKey: enabledBrowsersKey)
        }
    }

    /// Hosts never recorded. Matched on the entry host and any parent domain, so
    /// `example.com` also blocks `mail.example.com`.
    var blockedDomains: [String] {
        didSet { UserDefaults.standard.set(blockedDomains, forKey: blockedDomainsKey) }
    }

    /// Skip private/incognito windows. Effective for Chromium browsers only —
    /// see the privacy note in the type doc.
    var skipsPrivateWindows: Bool {
        didSet { UserDefaults.standard.set(skipsPrivateWindows, forKey: skipsPrivateKey) }
    }

    /// Drop `?query` and `#fragment` before recording. Off by default because it
    /// breaks any URL that carries real state in the query (search results, most
    /// SPAs); on, it collapses tracking-parameter variants of one page into one
    /// entry.
    var stripsQueryStrings: Bool {
        didSet { UserDefaults.standard.set(stripsQueryStrings, forKey: stripsQueryKey) }
    }

    private let historyKey = "glancekit.browsing.history"
    private let maxEntriesKey = "glancekit.browsing.maxEntries"
    private let pausedKey = "glancekit.browsing.paused"
    private let pausedUntilKey = "glancekit.browsing.pausedUntil"
    private let clearOnQuitKey = "glancekit.browsing.clearOnQuit"
    private let enabledBrowsersKey = "glancekit.browsing.enabledBrowsers"
    private let blockedDomainsKey = "glancekit.browsing.blockedDomains"
    private let skipsPrivateKey = "glancekit.browsing.skipsPrivate"
    private let stripsQueryKey = "glancekit.browsing.stripsQuery"
    private let firefoxWatermarkKey = "glancekit.browsing.firefoxWatermark"

    /// Cap stored strings so a pathological URL or title can't bloat UserDefaults.
    private let maxStoredChars = 2_000

    /// The newest entry, once it has been seen on a second poll tick — i.e. a
    /// page the user actually stayed on rather than passed through. Transient by
    /// design: on relaunch the restored head is simply treated as unconfirmed,
    /// and the worst case is that one old entry becomes eligible for transit
    /// collapse, which `transitWindow` immediately rules out anyway.
    private var confirmedHeadID: UUID?

    /// How long after recording an entry it can still be retracted as a transit
    /// page. Must exceed one refresh tick so a real page always gets the chance
    /// to be confirmed first.
    private let transitWindow: TimeInterval = 2.5

    /// Firefox's history is read by watermark rather than by polling a tab:
    /// the newest `visit_date` (microseconds since epoch) already recorded.
    private var firefoxWatermark: Int64 {
        didSet { UserDefaults.standard.set(firefoxWatermark, forKey: firefoxWatermarkKey) }
    }

    /// Firefox reads copy a multi-megabyte database, so they run on their own,
    /// much slower cadence than the Apple Event polls.
    private var lastFirefoxRead: Date = .distantPast
    private let firefoxInterval: TimeInterval = 15

    init() {
        let defaults = UserDefaults.standard
        let storedMax = defaults.integer(forKey: maxEntriesKey)
        maxEntries = storedMax == 0 ? 100 : min(500, max(25, storedMax))
        isPaused = defaults.bool(forKey: pausedKey)
        clearOnQuit = defaults.bool(forKey: clearOnQuitKey)
        blockedDomains = defaults.stringArray(forKey: blockedDomainsKey) ?? []

        // Both privacy toggles default to their safe value, so a fresh install
        // that has never written the key must read as `true`, not `false`.
        skipsPrivateWindows = defaults.object(forKey: skipsPrivateKey) as? Bool ?? true
        stripsQueryStrings = defaults.bool(forKey: stripsQueryKey)

        let storedBrowsers = defaults.stringArray(forKey: enabledBrowsersKey) ?? []
        enabledBrowsers = Set(storedBrowsers.compactMap(Browser.init(rawValue:)))

        // Start Firefox at "now" rather than importing years of existing history:
        // this glance records what you browse while it's running, like Clipboard.
        let storedWatermark = defaults.object(forKey: firefoxWatermarkKey) as? Int64
        firefoxWatermark = storedWatermark ?? Int64(Date().timeIntervalSince1970 * 1_000_000)

        // Restore a timed pause only if it hasn't elapsed while the app was closed.
        if defaults.object(forKey: pausedUntilKey) != nil {
            let until = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: pausedUntilKey))
            pausedUntil = until > Date() ? until : nil
        } else {
            pausedUntil = nil
        }

        if let data = defaults.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }

        // Wipe unpinned history on quit when the user opted in. Runs on the main
        // queue, so we're already on the main actor.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.clearOnQuit else { return }
                self.clearHistory()
            }
        }
    }

    // MARK: GlancePlugin

    func refresh() async {
        // Timed pause: skip while active, clear once elapsed.
        if let until = pausedUntil {
            if until > Date() { return }
            pausedUntil = nil
        }
        guard !isPaused, !enabledBrowsers.isEmpty else { return }

        await pollFrontmostBrowser()
        await pollFirefox()
    }

    /// True when capturing is suspended right now, for any reason.
    var isCapturingSuspended: Bool {
        if isPaused { return true }
        if let until = pausedUntil, until > Date() { return true }
        return false
    }

    /// Pause capturing for a fixed interval (replaces any existing timed pause).
    func pause(for interval: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(interval)
    }

    /// Clear a timed pause immediately.
    func resumeTimedPause() {
        pausedUntil = nil
    }

    /// Browsing isn't time-sensitive; keep the feed quiet.
    func currentSignal() -> GlanceSignal? { nil }

    func popoverSection() -> AnyView { AnyView(BrowsingPopover(plugin: self)) }
    func settingsSection() -> AnyView { AnyView(BrowsingSettings(plugin: self)) }

    /// Automation is per-browser, and a partial grant is the normal case — one
    /// browser allowed, another not yet asked. Gating the whole popover on that
    /// would hide history we *can* read, so this only returns a gate in the one
    /// situation where the glance is genuinely inert: scriptable browsers are
    /// enabled, none of them is permitted, and there's nothing recorded to show.
    /// Otherwise the popover shows a per-browser banner instead.
    var requiredPermissions: [GlancePermission] {
        guard entries.isEmpty, !scriptableBrowsers.isEmpty,
              scriptableBrowsers.allSatisfy({ AutomationPermission.status(for: $0.bundleID) != .granted })
        else { return [] }

        return scriptableBrowsers.map { browser in
            GlancePermission(
                id: "automation.\(browser.rawValue)",
                title: "Automation — \(browser.displayName)",
                iconSystemName: browser.systemImage,
                rationale: "Read the active tab's address so it can be recorded.",
                status: { AutomationPermission.status(for: browser.bundleID) },
                request: { await AutomationPermission.request(for: browser.bundleID) },
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            )
        }
    }

    /// Enabled browsers we reach over Apple Events (i.e. everything but Firefox).
    var scriptableBrowsers: [Browser] {
        enabledBrowsers.filter { $0.family != .firefox }.sorted { $0.rawValue < $1.rawValue }
    }

    /// Enabled, running, scriptable browsers that TCC hasn't granted us. Drives
    /// the popover's access banner.
    var browsersAwaitingAccess: [Browser] {
        scriptableBrowsers.filter { $0.isRunning && AutomationPermission.status(for: $0.bundleID) != .granted }
    }

    // MARK: Capture

    /// Ask the frontmost app for its active tab, if that app is a browser we're
    /// watching. Deliberately *only* the frontmost one: it bounds the Apple Event
    /// traffic to one call per tick, and it means we record what the user is
    /// actually looking at rather than every background window.
    private func pollFrontmostBrowser() async {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let browser = enabledBrowsers.first(where: { $0.bundleID == front }),
              let script = browser.activeTabScript
        else { return }

        guard let raw = await AppleScriptRunner.shared.run(script), !raw.isEmpty else { return }
        guard let tab = parseActiveTab(raw) else { return }
        observe(tab, from: browser)
    }

    /// `url \n title \n mode`, as produced by `Browser.activeTabScript`.
    private func parseActiveTab(_ raw: String) -> ActiveTab? {
        let lines = raw.components(separatedBy: "\n")
        guard let url = lines.first, !url.isEmpty else { return nil }
        let title = lines.count > 1 ? lines[1] : ""
        let mode = lines.count > 2 ? lines[2] : "normal"
        return ActiveTab(url: url, title: title, isPrivate: mode.lowercased().contains("incognito"))
    }

    /// Drain new Firefox visits since the watermark. Throttled, and skipped
    /// entirely unless Firefox is enabled and running.
    private func pollFirefox() async {
        guard enabledBrowsers.contains(.firefox), Browser.firefox.isRunning,
              Date().timeIntervalSince(lastFirefoxRead) >= firefoxInterval
        else { return }
        lastFirefoxRead = Date()

        let watermark = firefoxWatermark
        // File IO plus a SQLite read — off the main actor.
        let visits = await Task.detached(priority: .utility) {
            FirefoxHistory.visits(sinceMicros: watermark)
        }.value

        for visit in visits {
            firefoxWatermark = max(firefoxWatermark, visit.visitDateMicros)
            record(
                url: visit.url,
                title: visit.title,
                browser: .firefox,
                at: Date(timeIntervalSince1970: Double(visit.visitDateMicros) / 1_000_000)
            )
        }
    }

    /// Record a sighting, collapsing redirect hops after the fact.
    ///
    /// Every new URL is recorded on its **first** sighting, so nothing you
    /// actually land on is lost — including pages you click straight through.
    /// The cleanup runs in the other direction: when a *newer* URL arrives, the
    /// entry it displaces is deleted if it looks like a page you never really
    /// visited — recorded moments ago, in this same browser, never seen on a
    /// second tick, and not something you'd already visited before. That is
    /// precisely the profile of a redirect hop or an interstitial, and nothing
    /// else.
    private func observe(_ tab: ActiveTab, from browser: Browser) {
        if skipsPrivateWindows, tab.isPrivate { return }
        guard let canonical = canonicalize(tab.url) else { return }

        // Still on the newest entry: it survived a tick, so it's a real page.
        if let head = entries.first, head.url == canonical {
            confirmedHeadID = head.id
            return
        }

        if let head = entries.first, isTransit(head, supersededBy: browser) {
            entries.removeFirst()
        }
        record(url: canonical, title: tab.title, browser: browser, at: Date())
    }

    /// Whether `head` was a page passed through rather than visited, now that
    /// something newer has arrived in `browser`.
    private func isTransit(_ head: Entry, supersededBy browser: Browser) -> Bool {
        !head.pinned
            && head.browser == browser
            && head.visits == 1
            && head.id != confirmedHeadID
            && Date().timeIntervalSince(head.timestamp) < transitWindow
    }

    /// Normalize a URL for storage, or reject it. Returns `nil` for anything not
    /// worth recording — non-web schemes, blocked domains, malformed input.
    private func canonicalize(_ raw: String) -> String? {
        // `URLComponents` is strict RFC 3986, so a browser that hands back an
        // unencoded non-ASCII path (common on CJK sites) would otherwise be
        // dropped silently. Encode and retry before giving up.
        guard var components = URLComponents(string: raw)
                ?? raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
                    .flatMap(URLComponents.init(string:)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        components.fragment = nil
        if stripsQueryStrings { components.query = nil }

        guard let normalized = components.string else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard !isBlocked(bare) else { return nil }
        return String(normalized.prefix(maxStoredChars))
    }

    /// A host is blocked by an exact match or by any parent domain in the list.
    func isBlocked(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return blockedDomains.contains { domain in
            let d = domain.lowercased()
            return lowered == d || lowered.hasSuffix("." + d)
        }
    }

    /// Insert a visit, folding repeats into the existing entry.
    private func record(url: String, title: String, browser: Browser, at date: Date) {
        let storedTitle = String(title.prefix(maxStoredChars))

        if let idx = entries.firstIndex(where: { $0.url == url }) {
            var moved = entries.remove(at: idx)
            moved.timestamp = date
            moved.visits += 1
            // A later visit usually has the better title — the first sighting
            // often catches the page mid-load with an empty or placeholder one.
            if !storedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                moved.title = storedTitle
            }
            moved.browser = browser
            entries.insert(moved, at: 0)
            persist()
            return
        }

        entries.insert(Entry(url: url, title: storedTitle, browser: browser, timestamp: date), at: 0)
        trim()
        persist()
    }

    // MARK: Actions

    /// Reopen a page in the browser it was captured from, falling back to the
    /// system default if that browser has since been removed.
    func open(_ entry: Entry) {
        guard let url = URL(string: entry.url) else { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.browser.bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func copyURL(_ entry: Entry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.url, forType: .string)
    }

    func togglePin(_ entry: Entry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx].pinned.toggle()
        trim()
        persist()
    }

    /// Reorder the pinned entries. `offsets`/`destination` are indices into the
    /// pinned subsequence (as shown in the Pinned section). Unpinned order is
    /// preserved; the raw array is normalised to `pinned + unpinned`, which
    /// `sortedEntries` already assumes for display.
    func movePins(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var pinned = entries.filter { $0.pinned }
        guard !pinned.isEmpty else { return }
        pinned.move(fromOffsets: offsets, toOffset: destination)
        let unpinned = entries.filter { !$0.pinned }
        entries = pinned + unpinned
        persist()
    }

    func delete(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    /// Block an entry's domain and retroactively drop everything already
    /// recorded from it — blocking a site you regret visiting is only useful if
    /// it also clears the evidence.
    func blockDomain(of entry: Entry) {
        let host = entry.host
        guard !host.isEmpty, !isBlocked(host) else { return }
        blockedDomains.append(host)
        entries.removeAll { isBlocked($0.host) }
        persist()
    }

    func unblock(_ domain: String) {
        blockedDomains.removeAll { $0.caseInsensitiveCompare(domain) == .orderedSame }
    }

    /// Add a domain typed into Settings. Tolerates a pasted URL or a leading
    /// `www.`, since that's what people actually paste.
    func block(_ input: String) {
        var domain = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let host = URLComponents(string: domain)?.host { domain = host }
        if domain.hasPrefix("www.") { domain = String(domain.dropFirst(4)) }
        guard !domain.isEmpty, domain.contains("."), !blockedDomains.contains(domain) else { return }
        blockedDomains.append(domain)
        entries.removeAll { isBlocked($0.host) }
        persist()
    }

    /// Remove unpinned history, keeping pinned entries.
    func clearHistory() {
        entries.removeAll { !$0.pinned }
        persist()
    }

    /// Remove everything, pinned included.
    func clearAll() {
        entries.removeAll()
        persist()
    }

    /// Entries in display order: pinned first (each group newest-first).
    var sortedEntries: [Entry] {
        let pinned = entries.filter { $0.pinned }
        let rest = entries.filter { !$0.pinned }
        return pinned + rest
    }

    // MARK: Storage helpers

    /// Enforce the cap on unpinned entries; pinned entries are exempt.
    private func trim() {
        var kept: [Entry] = []
        var unpinnedCount = 0
        for entry in entries {
            if entry.pinned {
                kept.append(entry)
            } else if unpinnedCount < maxEntries {
                kept.append(entry)
                unpinnedCount += 1
            }
        }
        entries = kept
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
}
