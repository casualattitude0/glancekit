import Foundation
import AppKit
import Observation

/// Loads the strategy plan from a file on disk and reloads it whenever that
/// file changes.
///
/// The plan is regenerated every morning from a warm-up report, so the natural
/// interface is "point at a file and forget" rather than "paste JSON into a text
/// box daily". Overwrite the file, and the glance picks it up within a second.
///
/// The watch is on the **parent directory**, not the file. Almost everything
/// that writes a file — editors, `jq > tmp && mv`, most scripts — replaces it
/// atomically, which creates a *new* inode and leaves a file-level descriptor
/// watching a ghost. Watching the directory survives that; the cost is waking
/// on unrelated writes to sibling files, which the debounce absorbs.
/// A plan kept from a previous day, listed in the glance's 計畫記錄 menu.
struct ArchivedPlan: Identifiable, Equatable {
    let date: String
    let url: URL
    let stockCount: Int
    var id: String { date }
}

@MainActor
@Observable
final class StrategyPlanSource {
    static let bookmarkKey = "glancekit.stocks.planBookmark"

    private(set) var plan: StrategyPlan?
    /// Human-readable parse/read failure, surfaced in the popover. A plan that
    /// silently fails to load is the worst outcome here — you'd assume you were
    /// being watched when you weren't.
    private(set) var error: String?
    private(set) var displayPath: String?
    private(set) var loadedAt: Date?

    /// Previous days' plans, newest first. Every plan that loads is copied here,
    /// so yesterday's is still reachable when this morning's hasn't been
    /// generated yet — or when you want to see what you were actually looking at
    /// when a trade went the way it did.
    private(set) var archives: [ArchivedPlan] = []

    /// Non-nil while viewing an archived plan instead of the watched file.
    ///
    /// Pinning matters: the watcher keeps running (a new plan still gets
    /// archived), but it must not yank the display out from under you the
    /// moment the morning file lands while you're reading back through
    /// Thursday's levels.
    private(set) var pinnedArchiveDate: String?

    var isPinned: Bool { pinnedArchiveDate != nil }

    /// True when the loaded plan wasn't written for today — a stale plan quotes
    /// moving averages that have since moved, so the UI says so out loud.
    var isStale: Bool {
        guard let date = plan?.date else { return false }
        return date != TWMarketClock.tradingDay()
    }

    /// Called on the main actor after a successful reload.
    var onChange: (() -> Void)?

    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryFD: CInt = -1
    private var scopedURL: URL?
    private var pendingReload: DispatchWorkItem?

    // MARK: Lifecycle

    /// Resolve the persisted bookmark, load, and start watching. Safe to call
    /// repeatedly; a no-op when no file has been chosen.
    func start() {
        rescanArchives()
        guard let url = resolveBookmark() else { return }
        adopt(url)
    }

    /// Prompt for a plan file and adopt it. Callable from the glance itself, not
    /// only Settings — importing the morning's plan is a daily action, and
    /// making it a trip through a settings window would be a daily tax.
    func chooseFile() {
        // A tool window dismisses itself when it stops being key, and the open
        // panel takes key — so without this, picking a file closes the very
        // window you were picking it for. Must resume on the cancel path too.
        ToolWindowManager.shared.suspendAutoClose()
        defer { ToolWindowManager.shared.resumeAutoClose() }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "選擇"
        panel.message = "選擇每日交易計畫 JSON"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pinnedArchiveDate = nil
        saveBookmark(for: url)
        adopt(url)
    }

    // MARK: Archives

    /// Show a previous day's plan. The watched file keeps being watched and
    /// archived underneath; it just stops driving the display until `goLive()`.
    func loadArchive(_ archive: ArchivedPlan) {
        guard let data = try? Data(contentsOf: archive.url),
              let decoded = try? JSONDecoder().decode(StrategyPlan.self, from: data) else {
            error = "無法讀取 \(archive.date) 的計畫"
            return
        }
        pinnedArchiveDate = archive.date
        plan = decoded
        loadedAt = Date()
        error = validationWarning(for: decoded)
        onChange?()
    }

    /// Promote the archived plan you're viewing to the active one, so its levels
    /// start firing notifications again.
    ///
    /// This exists because "show me Thursday's plan" has two meanings that must
    /// not be guessed at: reviewing what you were looking at when a trade went
    /// wrong, and actually trading it because this morning's plan never got
    /// generated. Viewing is the safe default (alerts stay paused); this is the
    /// deliberate second step for the other case.
    func activatePinned() {
        guard isPinned else { return }
        pinnedArchiveDate = nil
        onChange?()
    }

    /// Inject a decoded plan directly. Rendering/preview seam only — the app
    /// itself always goes through the watched file or an archive.
    func adoptForPreview(_ plan: StrategyPlan) {
        self.plan = plan
        loadedAt = Date()
        onChange?()
    }

    /// Return to the live watched file.
    func goLive() {
        pinnedArchiveDate = nil
        guard let url = scopedURL ?? resolveBookmark() else {
            plan = nil
            onChange?()
            return
        }
        load(from: url)
    }

    /// Keep a copy of a plan under its own date. Same-date reloads overwrite,
    /// so editing this morning's plan doesn't accumulate near-duplicates.
    private func archive(_ plan: StrategyPlan, data: Data) {
        let date = plan.date ?? TWMarketClock.tradingDay()
        // Never let a stray `date` value escape into a path.
        let safe = date.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !safe.isEmpty else { return }
        try? data.write(to: archiveDirectory.appendingPathComponent("\(safe).json"), options: [.atomic])
        rescanArchives()
    }

    private var archiveDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Glancekit/stock-plans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Rebuild the archive list from disk, newest first, pruning the tail.
    private func rescanArchives() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: archiveDirectory, includingPropertiesForKeys: nil) else { return }

        var found: [ArchivedPlan] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let decoded = try? JSONDecoder().decode(StrategyPlan.self, from: data) else { continue }
            found.append(ArchivedPlan(
                date: decoded.date ?? file.deletingPathExtension().lastPathComponent,
                url: file,
                stockCount: decoded.plans.count))
        }
        found.sort { $0.date > $1.date }

        // A plan a quarter old is history, not a working reference.
        for stale in found.dropFirst(Self.maxArchives) {
            try? FileManager.default.removeItem(at: stale.url)
        }
        archives = Array(found.prefix(Self.maxArchives))
    }

    private static let maxArchives = 60

    /// Forget the file. The file itself is untouched.
    func clear() {
        stopWatching()
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        pinnedArchiveDate = nil
        plan = nil
        error = nil
        displayPath = nil
        loadedAt = nil
        onChange?()
    }

    /// Re-read the current file right now.
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
            let decoded = try JSONDecoder().decode(StrategyPlan.self, from: data)

            // Archive first and unconditionally: the history should record every
            // plan that ever landed in the watched file, including ones written
            // while you were reading back through an older day.
            archive(decoded, data: data)

            guard !isPinned else { return }
            plan = decoded
            loadedAt = Date()
            error = validationWarning(for: decoded)
        } catch let decodingError as DecodingError {
            error = "計畫解析失敗：\(readable(decodingError))"
        } catch let readError {
            error = "計畫讀取失敗：\(readError.localizedDescription)"
        }
        onChange?()
    }

    /// Non-fatal problems worth saying out loud — chiefly a `stockId` that
    /// doesn't parse, which would otherwise just quietly never be watched.
    private func validationWarning(for plan: StrategyPlan) -> String? {
        let unparsed = plan.plans.filter { $0.symbol == nil }.map(\.stockId)
        guard !unparsed.isEmpty else { return nil }
        return "無法辨識代號：\(unparsed.joined(separator: "、"))（上櫃請寫成 TPEX-3491）"
    }

    private func readable(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx):
            return "缺少 \(key.stringValue)（\(path(ctx))）"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            return "\(ctx.debugDescription)（\(path(ctx))）"
        case .dataCorrupted(let ctx):
            return ctx.debugDescription
        @unknown default:
            return error.localizedDescription
        }
    }

    private func path(_ ctx: DecodingError.Context) -> String {
        ctx.codingPath.map(\.stringValue).joined(separator: ".")
    }

    // MARK: Watching

    private func startWatching(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleReload(url) }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        directorySource = source
    }

    /// Coalesce the burst of events an atomic replace produces (and any noise
    /// from sibling files) into a single reload.
    private func scheduleReload(_ url: URL) {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
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
        directoryFD = -1
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    // MARK: Bookmark

    private func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url
    }

    private func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }
}
