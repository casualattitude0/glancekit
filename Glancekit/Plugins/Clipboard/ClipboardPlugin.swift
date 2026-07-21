import SwiftUI
import Observation
import AppKit

/// Clipboard History glance.
///
/// Polls `NSPasteboard.general` once a second (via `refreshInterval`) and records
/// each new clipboard entry into a persisted ring buffer. The popover is a
/// searchable list; clicking a row copies it back to the pasteboard. Pinned
/// entries survive the size cap and sort to the top.
///
/// PRIVACY: entries whose pasteboard declares the well-known concealed/transient
/// markers (`org.nspasteboard.ConcealedType` / `org.nspasteboard.TransientType`,
/// set by password managers and similar tools) are never recorded. Image data is
/// never stored — only a placeholder entry. Nothing here is a secret, so all
/// prefs live in plain `UserDefaults`.
@MainActor
@Observable
final class ClipboardPlugin: GlancePlugin {
    nonisolated var id: String { "clipboard" }
    nonisolated var title: String { "Clipboard" }
    nonisolated var iconSystemName: String { "doc.on.clipboard" }

    /// Poll the pasteboard once a second so we catch copies promptly.
    var refreshInterval: TimeInterval { 1 }

    var preferredToolWindowSize: CGSize? { CGSize(width: 360, height: 460) }
    var fillsToolWindow: Bool { true }

    // MARK: Entry model

    enum EntryType: String, Codable {
        case plainText
        case url
        case colorHex
        case image

        var systemImage: String {
            switch self {
            case .plainText: return "text.alignleft"
            case .url: return "link"
            case .colorHex: return "paintpalette"
            case .image: return "photo"
            }
        }
    }

    struct Entry: Identifiable, Codable, Equatable {
        var id: UUID
        var text: String
        var type: EntryType
        var timestamp: Date
        var pinned: Bool

        init(id: UUID = UUID(), text: String, type: EntryType, timestamp: Date = Date(), pinned: Bool = false) {
            self.id = id
            self.text = text
            self.type = type
            self.timestamp = timestamp
            self.pinned = pinned
        }
    }

    // MARK: Persisted state

    private(set) var entries: [Entry] = []

    /// Max number of *unpinned* entries kept. Pinned entries don't count. The
    /// settings Stepper is bounded 10...200; never self-assign here (didSet would
    /// re-enter), so we clamp on read from storage in `init` instead.
    var maxEntries: Int {
        didSet {
            UserDefaults.standard.set(maxEntries, forKey: maxEntriesKey)
            trim()
            persist()
        }
    }

    /// When true, refresh() observes but does not record new entries.
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

    /// Max characters of an entry shown in the list (full text is still stored and
    /// copied). Bounded 40...1000 on read.
    var previewLength: Int {
        didSet { UserDefaults.standard.set(previewLength, forKey: previewLengthKey) }
    }

    /// When true, all unpinned history is wiped when the app terminates.
    var clearOnQuit: Bool {
        didSet { UserDefaults.standard.set(clearOnQuit, forKey: clearOnQuitKey) }
    }

    /// One-shot: skip recording the very next clipboard change, then reset.
    var ignoreNextCopy: Bool = false

    private let historyKey = "glancekit.clipboard.history"
    private let maxEntriesKey = "glancekit.clipboard.maxEntries"
    private let pausedKey = "glancekit.clipboard.paused"
    private let pausedUntilKey = "glancekit.clipboard.pausedUntil"
    private let previewLengthKey = "glancekit.clipboard.previewLength"
    private let clearOnQuitKey = "glancekit.clipboard.clearOnQuit"

    /// Cap stored text so a huge paste can't bloat UserDefaults.
    private let maxStoredChars = 20_000

    /// The last `changeCount` we observed, so we only react to genuine changes.
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    /// The `changeCount` produced by our own write-back, so re-copying a row
    /// doesn't get re-captured as a brand-new entry.
    private var selfWriteChangeCount: Int = -1

    init() {
        let defaults = UserDefaults.standard
        let storedMax = defaults.integer(forKey: maxEntriesKey)
        maxEntries = storedMax == 0 ? 50 : min(200, max(10, storedMax))
        isPaused = defaults.bool(forKey: pausedKey)
        clearOnQuit = defaults.bool(forKey: clearOnQuitKey)

        let storedPreview = defaults.integer(forKey: previewLengthKey)
        previewLength = storedPreview == 0 ? 120 : min(1000, max(40, storedPreview))

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
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Ignore the change our own write-back produced.
        if current == selfWriteChangeCount { return }

        // Timed pause: skip while active, clear once elapsed.
        if let until = pausedUntil {
            if until > Date() { return }
            pausedUntil = nil
        }
        if isPaused { return }

        // One-shot skip for an intentional "don't record this" copy.
        if ignoreNextCopy {
            ignoreNextCopy = false
            return
        }

        capture(from: pb)
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

    /// Clipboard isn't time-sensitive; keep the feed quiet.
    func currentSignal() -> GlanceSignal? { nil }

    func popoverSection() -> AnyView { AnyView(ClipboardPopover(plugin: self)) }
    func settingsSection() -> AnyView { AnyView(ClipboardSettings(plugin: self)) }

    // MARK: Capture

    private func capture(from pb: NSPasteboard) {
        // PRIVACY: skip anything a password manager marked concealed/transient.
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        if let types = pb.types, types.contains(concealed) || types.contains(transient) {
            return
        }

        if let raw = pb.string(forType: .string) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let stored = String(trimmed.prefix(maxStoredChars))
            record(text: stored, type: detectType(stored))
            return
        }

        // No string, but an image is present: record a placeholder (no bytes).
        let hasImage = pb.canReadItem(withDataConformingToTypes: [
            "public.png", "public.tiff", "public.jpeg"
        ])
        if hasImage {
            record(text: "🖼 Image", type: .image)
        }
    }

    private func detectType(_ text: String) -> EntryType {
        if isHexColor(text) { return .colorHex }
        if isWebURL(text) { return .url }
        return .plainText
    }

    private func isWebURL(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && (url.host?.isEmpty == false)
    }

    private func isHexColor(_ text: String) -> Bool {
        guard text.hasPrefix("#") else { return false }
        let hex = text.dropFirst()
        guard hex.count == 3 || hex.count == 6 || hex.count == 8 else { return false }
        return hex.allSatisfy { $0.isHexDigit }
    }

    /// Insert a captured entry, applying dedup rules.
    private func record(text: String, type: EntryType) {
        // Same as the current most-recent entry → nothing changed.
        if let first = entries.first, first.text == text {
            return
        }
        // Exact match elsewhere → move it to the top instead of duplicating.
        if let idx = entries.firstIndex(where: { $0.text == text }) {
            var moved = entries.remove(at: idx)
            moved.timestamp = Date()
            entries.insert(moved, at: 0)
            persist()
            return
        }
        entries.insert(Entry(text: text, type: type), at: 0)
        trim()
        persist()
    }

    // MARK: Actions

    /// Copy an entry back to the pasteboard without re-capturing it.
    func copyToPasteboard(_ entry: Entry) {
        guard entry.type != .image else { return } // no bytes stored to restore
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
        // Remember the resulting changeCount so refresh() skips it, and move the
        // entry to the top so it reflects "most recently used".
        selfWriteChangeCount = pb.changeCount
        lastChangeCount = pb.changeCount
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            var moved = entries.remove(at: idx)
            moved.timestamp = Date()
            entries.insert(moved, at: 0)
            persist()
        }
    }

    /// Open a URL entry in the default browser.
    func openInBrowser(_ entry: Entry) {
        guard entry.type == .url, let url = URL(string: entry.text) else { return }
        NSWorkspace.shared.open(url)
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

// MARK: - Popover UI

/// Type facet for the popover filter bar. Maps onto `EntryType` (Text folds in
/// both plain text and any non-URL/color text).
private enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all, text, links, colors, images
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .links: return "Links"
        case .colors: return "Colors"
        case .images: return "Images"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .links: return "link"
        case .colors: return "paintpalette"
        case .images: return "photo"
        }
    }

    func matches(_ type: ClipboardPlugin.EntryType) -> Bool {
        switch self {
        case .all: return true
        case .text: return type == .plainText
        case .links: return type == .url
        case .colors: return type == .colorHex
        case .images: return type == .image
        }
    }
}

private struct ClipboardPopover: View {
    let plugin: ClipboardPlugin
    @State private var search: String = ""
    @State private var filter: ClipboardFilter = .all

    private func matches(_ entry: ClipboardPlugin.Entry) -> Bool {
        guard filter.matches(entry.type) else { return false }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return entry.text.localizedCaseInsensitiveContains(q)
    }

    private var pinnedFiltered: [ClipboardPlugin.Entry] {
        plugin.sortedEntries.filter { $0.pinned && matches($0) }
    }

    private var unpinnedFiltered: [ClipboardPlugin.Entry] {
        plugin.sortedEntries.filter { !$0.pinned && matches($0) }
    }

    /// Reorder is only coherent when the Pinned section shows the full pinned set
    /// in its stored order — i.e. no search and no type narrowing.
    private var canReorder: Bool {
        search.trimmingCharacters(in: .whitespaces).isEmpty && filter == .all
    }

    private var nothingToShow: Bool {
        pinnedFiltered.isEmpty && unpinnedFiltered.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField

            Picker("Filter", selection: $filter) {
                ForEach(ClipboardFilter.allCases) { f in
                    Label(f.label, systemImage: f.systemImage).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if plugin.isCapturingSuspended {
                pauseBanner
            }

            if nothingToShow {
                emptyState
            } else {
                List {
                    if !pinnedFiltered.isEmpty {
                        Section("Pinned") {
                            ForEach(pinnedFiltered) { entry in
                                ClipboardRow(plugin: plugin, entry: entry)
                            }
                            .onMove(perform: canReorder ? { plugin.movePins(fromOffsets: $0, toOffset: $1) } : nil)
                        }
                    }
                    if !unpinnedFiltered.isEmpty {
                        if pinnedFiltered.isEmpty {
                            Section {
                                ForEach(unpinnedFiltered) { entry in
                                    ClipboardRow(plugin: plugin, entry: entry)
                                }
                            }
                        } else {
                            Section("History") {
                                ForEach(unpinnedFiltered) { entry in
                                    ClipboardRow(plugin: plugin, entry: entry)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            footer
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search clipboard…", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: plugin.entries.isEmpty ? "doc.on.clipboard" : "line.3.horizontal.decrease.circle")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private var emptyMessage: String {
        if plugin.entries.isEmpty { return "Nothing copied yet." }
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return "No matches for your search." }
        if filter != .all { return "No \(filter.label.lowercased()) entries." }
        return "Nothing to show."
    }

    private var pauseBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            Text(pauseText).font(.caption)
            Spacer(minLength: 4)
            Button("Resume") {
                plugin.isPaused = false
                plugin.resumeTimedPause()
            }
            .buttonStyle(.plain)
            .font(.caption.bold())
            .foregroundStyle(.tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var pauseText: String {
        if plugin.isPaused { return "Capturing paused" }
        if let until = plugin.pausedUntil {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .short
            return "Paused \(fmt.localizedString(for: until, relativeTo: Date()))"
        }
        return "Capturing paused"
    }

    @ViewBuilder
    private var footer: some View {
        if !plugin.entries.isEmpty {
            Divider()
            HStack {
                Button {
                    plugin.clearHistory()
                } label: {
                    Label("Clear history", systemImage: "trash").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Menu {
                    Button("Ignore next copy") { plugin.ignoreNextCopy = true }
                    Divider()
                    Button("Pause 15 minutes") { plugin.pause(for: 15 * 60) }
                    Button("Pause 1 hour") { plugin.pause(for: 60 * 60) }
                    Button("Pause until resumed") { plugin.isPaused = true }
                } label: {
                    Label("Capture", systemImage: "pause.circle").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ClipboardRow: View {
    let plugin: ClipboardPlugin
    let entry: ClipboardPlugin.Entry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            leadingIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(preview)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.type != .image, showsSubtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if hovering {
                Button {
                    plugin.togglePin(entry)
                } label: {
                    Image(systemName: entry.pinned ? "star.fill" : "star")
                        .foregroundStyle(entry.pinned ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(entry.pinned ? "Unpin" : "Pin")

                Button {
                    plugin.delete(entry)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete")
            } else {
                if entry.pinned {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                }
                Text(relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { plugin.copyToPasteboard(entry) }
        .onHover { hovering = $0 }
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .help(tooltip)
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if entry.type == .colorHex, let color = Color(hex: entry.text) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.quaternary))
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: entry.type.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            plugin.copyToPasteboard(entry)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(entry.type == .image)

        if entry.type == .url {
            Button {
                plugin.openInBrowser(entry)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
        }

        Button {
            plugin.togglePin(entry)
        } label: {
            Label(entry.pinned ? "Unpin" : "Pin", systemImage: entry.pinned ? "star.slash" : "star")
        }

        Divider()

        Text(countSummary)

        Divider()

        Button(role: .destructive) {
            plugin.delete(entry)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Capped tooltip so a huge entry doesn't produce an unwieldy overlay.
    private var tooltip: String {
        entry.text.count > 500 ? String(entry.text.prefix(500)) + "…" : entry.text
    }

    private var preview: String {
        let flattened = entry.text.replacingOccurrences(of: "\n", with: " ")
        if flattened.count > plugin.previewLength {
            return String(flattened.prefix(plugin.previewLength)) + "…"
        }
        return flattened
    }

    private var lineCount: Int {
        entry.text.isEmpty ? 0 : entry.text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private var countSummary: String {
        let chars = entry.text.count
        let charStr = "\(chars) char\(chars == 1 ? "" : "s")"
        guard lineCount > 1 else { return charStr }
        return "\(charStr) · \(lineCount) lines"
    }

    /// Only worth a subtitle line when the entry is long or multi-line.
    private var showsSubtitle: Bool {
        entry.text.count > 80 || lineCount > 1
    }

    private var subtitle: String { countSummary }

    private var relativeTime: String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: entry.timestamp, relativeTo: Date())
    }
}

// MARK: - Settings UI

private struct ClipboardSettings: View {
    @Bindable var plugin: ClipboardPlugin

    var body: some View {
        SettingsPage("Clipboard") {
            Stepper(value: $plugin.maxEntries, in: 10...200, step: 10) {
                Text("Max history: \(plugin.maxEntries) items")
            }
            SettingsHelp("Pinned items are always kept and don't count toward this limit.")

            Stepper(value: $plugin.previewLength, in: 40...1000, step: 20) {
                Text("Preview length: \(plugin.previewLength) chars")
            }
            SettingsHelp("How much of each entry is shown in the list. Full text is always stored and copied.")

            Divider()

            SettingsToggleRow("Pause capturing", isOn: $plugin.isPaused)
            if let until = plugin.pausedUntil, until > Date() {
                SettingsHelp("Timed pause active until \(until.formatted(date: .omitted, time: .shortened)).")
            }

            SettingsToggleRow(
                "Clear history when quitting",
                detail: "On quit, removes unpinned items. Pinned items are kept.",
                isOn: $plugin.clearOnQuit)

            Divider()

            Button(role: .destructive) {
                plugin.clearAll()
            } label: {
                Label("Clear all history", systemImage: "trash")
            }
            SettingsHelp("Removes every item, including pinned ones.")
        }
    }
}

// MARK: - Color hex helper

private extension Color {
    /// Parse "#RGB", "#RRGGBB", or "#RRGGBBAA" into a Color. Returns nil if malformed.
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }

        let r, g, b, a: Double
        switch s.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            return nil
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
