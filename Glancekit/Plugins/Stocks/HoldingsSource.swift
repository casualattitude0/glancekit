import Foundation
import AppKit
import Observation

/// Watches the exported portfolio file, the same way `StrategyPlanSource`
/// watches the plan: pick it once, overwrite it whenever, and the glance keeps
/// up without being told.
///
/// Kept separate from the plan on purpose. The portfolio changes when you
/// trade; the plan changes when you re-plan. Tying them to one file would mean
/// re-importing both every time either moved.
@MainActor
@Observable
final class HoldingsSource {
    static let bookmarkKey = "glancekit.stocks.holdingsBookmark"

    private(set) var holdings: Holdings?
    private(set) var error: String?
    private(set) var displayPath: String?

    /// Called on the main actor after a successful reload.
    var onChange: (() -> Void)?

    private var directorySource: DispatchSourceFileSystemObject?
    private var scopedURL: URL?
    private var pendingReload: DispatchWorkItem?

    /// The file exactly as parsed, so a save can rewrite only the fields being
    /// edited. Round-tripping through `Holdings` instead would silently drop
    /// any key this app doesn't know about — a broker note, a lot id, whatever
    /// the export grows next — and losing a field you added is a bad way to
    /// find out the app rewrote your file.
    private var rawObject: [String: Any]?

    /// Writes trip the directory watcher. Reloading our own save is harmless
    /// but pointless churn, and it would fight the editor if one is open.
    private var ignoreReloadsUntil: Date?

    /// True when the app can write back — i.e. a file has been chosen.
    var canEdit: Bool { scopedURL != nil || resolveBookmark() != nil }

    /// True when the file's own `updatedAt` isn't today — stale share counts
    /// are worse than none, because they look authoritative.
    var isStale: Bool {
        guard let updated = holdings?.updatedAt else { return false }
        return updated != TWMarketClock.tradingDay()
    }

    func start() {
        guard let url = resolveBookmark() else { return }
        adopt(url)
    }

    /// Prompt for the exported holdings file.
    func chooseFile() {
        // Same reason as the plan picker: the open panel takes key, and a tool
        // window closes when it loses key. Resume on the cancel path too.
        ToolWindowManager.shared.suspendAutoClose()
        defer { ToolWindowManager.shared.resumeAutoClose() }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "選擇"
        panel.message = "選擇持股 JSON（holding.json）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(for: url)
        adopt(url)
    }

    /// Inject decoded holdings directly. Rendering/preview seam only.
    func adoptForPreview(_ holdings: Holdings) {
        self.holdings = holdings
        onChange?()
    }

    // MARK: Editing

    /// Write edited holdings back to the watched file.
    ///
    /// The file is the portfolio, so an edit belongs in it rather than in some
    /// parallel app-side copy that would quietly disagree with the next export.
    /// The consequence is worth stating plainly: **re-exporting from your
    /// journal overwrites anything edited here.** That's the right precedence
    /// — the journal is the record — but it means an in-app edit is a
    /// correction until the next export, not a permanent one.
    ///
    /// Returns an error string, or nil on success.
    @discardableResult
    func save(_ edited: Holdings) -> String? {
        guard let url = scopedURL ?? resolveBookmark() else {
            return "尚未選擇持股檔，無法儲存"
        }

        let root = Self.merged(edited, into: rawObject)
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "無法產生 JSON"
        }

        // Suppress the reload our own write is about to trigger.
        ignoreReloadsUntil = Date().addingTimeInterval(2)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            ignoreReloadsUntil = nil
            return "寫入失敗：\(error.localizedDescription)"
        }

        rawObject = root
        holdings = edited
        self.error = nil
        onChange?()
        return nil
    }

    /// The portfolio as JSON text, byte-for-byte what `save` would write.
    ///
    /// Deliberately routed through `merged` rather than re-encoding `Holdings`:
    /// a `Codable` round trip would silently drop every key this app doesn't
    /// model, and a copy that quietly loses fields is worse than no copy at all
    /// — you'd only find out after pasting it back over the original. Going
    /// through `merged` also means copy and save can never drift apart, since
    /// there is only one place that decides what the file looks like.
    ///
    /// Reflects the current in-app state, including edits made here, because
    /// that is what the panel is showing when you press the button.
    func exportJSON() -> String? {
        guard let holdings else { return nil }
        let root = Self.merged(holdings, into: rawObject)
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Fold edited values into the file's own JSON, leaving everything this app
    /// doesn't model untouched.
    ///
    /// Pure and static so it can be tested without a real file or bookmark —
    /// which matters, because the failure it guards against (silently dropping
    /// a key) is invisible until you go looking for the key.
    static func merged(_ edited: Holdings, into raw: [String: Any]?) -> [String: Any] {
        var root = raw ?? [:]
        // Editing makes the file current by definition.
        root["updatedAt"] = edited.updatedAt ?? TWMarketClock.tradingDay()
        if let cash = edited.cash { root["cash"] = cash } else { root["cash"] = NSNull() }

        // Merge per position by stockId so unknown per-position keys survive.
        var existing: [String: [String: Any]] = [:]
        for entry in (root["positions"] as? [[String: Any]] ?? []) {
            if let id = entry["stockId"] as? String { existing[id] = entry }
        }
        root["positions"] = edited.positions.map { position -> [String: Any] in
            var dict = existing[position.stockId] ?? [:]
            dict["stockId"] = position.stockId
            if let name = position.name, !name.isEmpty { dict["name"] = name }
            dict["shares"] = position.shares
            dict["avgCost"] = position.avgCost
            return dict
        }
        return root
    }

    func clear() {
        stopWatching()
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        holdings = nil
        error = nil
        displayPath = nil
        onChange?()
    }

    func reload() {
        guard let url = scopedURL ?? resolveBookmark() else { return }
        load(from: url)
    }

    // MARK: Loading

    private func adopt(_ url: URL) {
        stopWatching()
        scopedURL = url
        _ = url.startAccessingSecurityScopedResource()
        displayPath = (url.path as NSString).abbreviatingWithTildeInPath
        load(from: url)
        startWatching(url)
    }

    private func load(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Holdings.self, from: data)
            rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            holdings = decoded
            let unparsed = decoded.positions.filter { $0.symbol == nil }.map(\.stockId)
            error = unparsed.isEmpty ? nil
                : "無法辨識代號：\(unparsed.joined(separator: "、"))"
        } catch {
            self.error = "持股讀取失敗：\(error.localizedDescription)"
        }
        onChange?()
    }

    // MARK: Watching

    /// Watches the parent directory, not the file — an atomic rewrite swaps the
    /// inode and would strand a file-level descriptor on a ghost.
    private func startWatching(_ url: URL) {
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload(url) }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        directorySource = source
    }

    private func scheduleReload(_ url: URL) {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let until = self.ignoreReloadsUntil, Date() < until { return }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            self.load(from: url)
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func stopWatching() {
        pendingReload?.cancel()
        pendingReload = nil
        directorySource?.cancel()
        directorySource = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    // MARK: Bookmark

    private func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                        relativeTo: nil, bookmarkDataIsStale: &isStale)
    }

    private func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }
}
