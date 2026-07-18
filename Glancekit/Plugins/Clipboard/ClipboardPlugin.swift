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

    private let historyKey = "glancekit.clipboard.history"
    private let maxEntriesKey = "glancekit.clipboard.maxEntries"
    private let pausedKey = "glancekit.clipboard.paused"

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

        if let data = defaults.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
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
        if isPaused { return }

        capture(from: pb)
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

    func togglePin(_ entry: Entry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx].pinned.toggle()
        trim()
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

private struct ClipboardPopover: View {
    let plugin: ClipboardPlugin
    @State private var search: String = ""

    private var filtered: [ClipboardPlugin.Entry] {
        let all = plugin.sortedEntries
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            if filtered.isEmpty {
                Text(plugin.entries.isEmpty ? "Nothing copied yet." : "No matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filtered) { entry in
                            ClipboardRow(plugin: plugin, entry: entry)
                        }
                    }
                }
            }

            if !plugin.entries.isEmpty {
                Divider()
                Button {
                    plugin.clearHistory()
                } label: {
                    Label("Clear history", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
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
            Image(systemName: entry.type.systemImage)
                .font(.caption)
                .foregroundStyle(entry.type == .colorHex ? swatchColor : .secondary)
                .frame(width: 16)

            Text(entry.text)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

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
    }

    private var relativeTime: String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: entry.timestamp, relativeTo: Date())
    }

    private var swatchColor: Color {
        guard entry.type == .colorHex else { return .secondary }
        return Color(hex: entry.text) ?? .secondary
    }
}

// MARK: - Settings UI

private struct ClipboardSettings: View {
    @Bindable var plugin: ClipboardPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Stepper(value: $plugin.maxEntries, in: 10...200, step: 10) {
                Text("Max history: \(plugin.maxEntries) items")
            }
            Text("Pinned items are always kept and don't count toward this limit.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Pause capturing", isOn: $plugin.isPaused)

            Divider()

            Button(role: .destructive) {
                plugin.clearAll()
            } label: {
                Label("Clear all history", systemImage: "trash")
            }
            Text("Removes every item, including pinned ones.")
                .font(.caption).foregroundStyle(.secondary)
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
