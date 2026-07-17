import SwiftUI
import AppKit
import Observation

/// Color picker / hex grabber glance.
///
/// Uses `NSColorSampler` to eyedrop any pixel on screen, copies the sRGB hex
/// string to the general pasteboard automatically, and keeps a small history
/// of recently picked swatches (persisted in `UserDefaults`).
///
/// - Menu-bar: contributes nothing (`menuBarSummary` is nil) — popover-only.
/// - Popover: a "Pick color" button, the most recent pick shown large with
///   hex + RGB, and a grid of recent swatches.
@MainActor
@Observable
final class ColorPickerPlugin: GlancePlugin {
    nonisolated var id: String { "colorpicker" }
    nonisolated var title: String { "Color Picker" }
    nonisolated var iconSystemName: String { "eyedropper" }
    var refreshInterval: TimeInterval { 0 }
    var menuBarSummary: String? { nil }

    private let recentKey = "glancekit.colorpicker.recent"
    private let uppercaseKey = "glancekit.colorpicker.uppercase"
    private let maxRecents = 12

    /// Most-recent-first list of picked hex strings.
    private(set) var recentHexes: [String]
    private(set) var lastPickedHex: String?
    private(set) var lastError: String?

    var uppercase: Bool {
        didSet { UserDefaults.standard.set(uppercase, forKey: uppercaseKey) }
    }

    init() {
        recentHexes = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        uppercase = UserDefaults.standard.object(forKey: uppercaseKey) as? Bool ?? true
        lastPickedHex = recentHexes.first
    }

    // MARK: GlancePlugin

    func refresh() async {
        // Nothing to auto-refresh; picking is user-initiated.
    }

    func popoverSection() -> AnyView {
        AnyView(ColorPickerPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(ColorPickerSettings(plugin: self))
    }

    // MARK: Actions

    /// Opens the system eyedropper. On pick, converts to sRGB hex, copies it
    /// to the pasteboard, and records it in history.
    func pickColor() {
        lastError = nil
        NSColorSampler().show { [weak self] color in
            guard let color else { return } // user cancelled
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let hex = ColorHex.hexString(from: color, uppercase: self.uppercase) else {
                    self.lastError = "Couldn't read that color"
                    return
                }
                self.recordPick(hex)
            }
        }
    }

    /// Re-copies an existing swatch's hex to the clipboard without adding a
    /// duplicate history entry (it just moves to the front).
    func selectSwatch(_ hex: String) {
        recordPick(hex)
    }

    func clearHistory() {
        recentHexes = []
        lastPickedHex = nil
        persistRecents()
    }

    func copyLatest() {
        guard let hex = lastPickedHex else { return }
        copyToPasteboard(hex)
    }

    // MARK: Helpers

    private func recordPick(_ hex: String) {
        lastPickedHex = hex
        copyToPasteboard(hex)
        var updated = recentHexes.filter { $0.caseInsensitiveCompare(hex) != .orderedSame }
        updated.insert(hex, at: 0)
        if updated.count > maxRecents { updated = Array(updated.prefix(maxRecents)) }
        recentHexes = updated
        persistRecents()
    }

    private func persistRecents() {
        UserDefaults.standard.set(recentHexes, forKey: recentKey)
    }

    private func copyToPasteboard(_ hex: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
    }
}

// MARK: - Popover UI

private struct ColorPickerPopover: View {
    let plugin: ColorPickerPlugin

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                plugin.pickColor()
            } label: {
                Label("Pick color", systemImage: "eyedropper")
                    .frame(maxWidth: .infinity)
            }

            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let hex = plugin.lastPickedHex, let color = ColorHex.color(fromHex: hex) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: color))
                        .frame(width: 44, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(hex)
                            .font(.body.monospaced().weight(.semibold))
                        if let rgb = ColorHex.rgbComponents(from: color) {
                            Text("R \(rgb.r)  G \(rgb.g)  B \(rgb.b)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button {
                        ColorFavoritesStore.shared.toggle(hex)
                    } label: {
                        Image(systemName: ColorFavoritesStore.shared.isFavorite(hex) ? "star.fill" : "star")
                            .foregroundStyle(ColorFavoritesStore.shared.isFavorite(hex) ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(ColorFavoritesStore.shared.isFavorite(hex) ? "Remove from favorites" : "Add to favorites")

                    Button("Copy") { plugin.copyLatest() }
                }
            } else {
                Text("No color picked yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !plugin.recentHexes.isEmpty {
                Divider()
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(plugin.recentHexes, id: \.self) { hex in
                        ColorSwatch(hex: hex) { plugin.selectSwatch(hex) }
                    }
                }
            }

            if !ColorFavoritesStore.shared.favorites.isEmpty {
                Divider()
                Text("Favorites")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(ColorFavoritesStore.shared.favorites, id: \.self) { hex in
                        ColorSwatch(hex: hex) { plugin.selectSwatch(hex) }
                            .contextMenu {
                                Button("Remove", role: .destructive) {
                                    ColorFavoritesStore.shared.remove(hex)
                                }
                            }
                    }
                }
            }
        }
    }
}

private struct ColorSwatch: View {
    let hex: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5)
                .fill(swatchColor)
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        .help(hex)
    }

    private var swatchColor: Color {
        guard let nsColor = ColorHex.color(fromHex: hex) else { return .gray }
        return Color(nsColor: nsColor)
    }
}

// MARK: - Settings UI

private struct ColorPickerSettings: View {
    @Bindable var plugin: ColorPickerPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Color Picker")
                .font(.headline)

            Toggle("Uppercase hex codes", isOn: $plugin.uppercase)

            Divider()

            Text("History")
                .font(.headline)
            Text("Keeps the last \(12) picked colors.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear history", role: .destructive) {
                plugin.clearHistory()
            }
            .disabled(plugin.recentHexes.isEmpty)

            Divider()

            Text("Favorites")
                .font(.headline)
            Text("Favorites are shared with the Color Palette tool.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear favorites", role: .destructive) {
                ColorFavoritesStore.shared.clear()
            }
            .disabled(ColorFavoritesStore.shared.favorites.isEmpty)
        }
    }
}
