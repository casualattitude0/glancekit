import SwiftUI
import AppKit
import Observation

/// Colors glance: eyedropper + palette in one tool.
///
/// Grabbing a color off screen and dialling one in by hand are the same job
/// with two input methods, so they share one surface: whichever way a color
/// arrives, it lands in the same live selection, which can be copied as an sRGB
/// hex string or starred into favorites.
///
/// HSB is the source of truth for the selection — the 2D field (saturation ×
/// brightness) and hue slider map onto it directly. Eyedropped colors are
/// converted into HSB via `select(hex:)`; the round-trip back to sRGB hex is
/// exact for 8-bit values, so a picked color reports the hex it was picked from.
///
/// A menu-bar/accessory app can't reliably surface the system `NSColorPanel`,
/// so the palette is drawn in-popover rather than delegating to it.
///
/// - Popover: a "Pick color" eyedropper button, the current color shown large
///   with hex + RGB + copy/favorite controls, an HSB field + hue slider, recent
///   picks, and favorites.
@MainActor
@Observable
final class ColorsPlugin: GlancePlugin {
    // This glance supersedes the old "colorpicker" and "colorpalette" ones. The
    // id is the persistence key for enabled/order state, so the retired ids are
    // rewritten to this one by `PluginRegistry.migrateColorGlances()`.
    nonisolated var id: String { "colors" }
    nonisolated var title: String { "Colors" }
    nonisolated var iconSystemName: String { "eyedropper" }
    var refreshInterval: TimeInterval { 0 }

    // Namespaced under this glance's id, per the plugin contract. Pick history
    // and the uppercase preference predate the merge under "colorpicker" names;
    // `migrateColorPickerKeys()` carries them across.
    private let recentKey = "glancekit.colors.recent"
    private let uppercaseKey = "glancekit.colors.uppercase"
    private let maxRecents = 12

    /// Current color in HSB, each component 0...1.
    var hue: Double = 0.58
    var saturation: Double = 1
    var brightness: Double = 1

    /// Most-recent-first list of picked hex strings.
    private(set) var recentHexes: [String]
    private(set) var lastError: String?

    var uppercase: Bool {
        didSet { UserDefaults.standard.set(uppercase, forKey: uppercaseKey) }
    }

    init() {
        // Must precede the reads below: they look at the new keys, which only
        // hold anything for a pre-merge user once the migration has moved them.
        Self.migrateColorPickerKeys()

        recentHexes = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        uppercase = UserDefaults.standard.object(forKey: uppercaseKey) as? Bool ?? true
        // Reopen on the last color picked, so the tool resumes where it left off.
        if let last = recentHexes.first { select(hex: last) }
    }

    // MARK: - Migrations

    /// One-shot: pick history and the uppercase preference were left under the
    /// pre-merge "colorpicker" names when the picker and palette glances merged
    /// into "colors" (favorites already moved). Two namespaces for one glance is
    /// a trap for whoever writes the next migration, so this closes the drift.
    ///
    /// The old key is the source of truth until the flag latches, and it wins
    /// unconditionally. No shipped build ever wrote a "colors" recent/uppercase
    /// key, so anything sitting there came from a dev build and is not user
    /// history worth protecting; the pre-merge value is. Letting the new key win
    /// instead needs a "did we already move this?" signal, and the only honest
    /// one is the flag, which is what this reads at the top.
    ///
    /// Order matters: latch the flag BEFORE deleting the old keys. Every kill
    /// point is then either safe or harmless.
    ///
    /// - Killed before the latch: the old keys are untouched and the new keys
    ///   hold a copy of them, so the next launch redoes identical work. Nothing
    ///   is lost because the plugin has not read anything yet, this being the
    ///   first statement of `init()`.
    /// - Killed after the latch, before the deletes: the new keys are correct
    ///   and the old ones linger as orphans that nothing reads. Harmless.
    ///
    /// Doing it the other way around (delete, then latch) would leave a window
    /// where both copies are gone. There is deliberately no read-back check: a
    /// `set` followed by a `get` hits the same in-memory cache, so a check could
    /// only ever fail spuriously, and the recovery path for a spurious failure
    /// is what would put the history at risk.
    ///
    /// This differs from `PluginRegistry.migrateColorGlances()`, which needs an
    /// early return before its `persist()` because its enabled key doubles as
    /// the "have we launched before" signal. This flag is private to this
    /// glance and gates nothing else, so writing it on a fresh install is inert.
    private static func migrateColorPickerKeys() {
        let defaults = UserDefaults.standard
        let migrationKey = "glancekit.migration.colorkeys"
        guard !defaults.bool(forKey: migrationKey) else { return }

        let moves = [
            ("glancekit.colorpicker.recent", "glancekit.colors.recent"),
            ("glancekit.colorpicker.uppercase", "glancekit.colors.uppercase"),
        ]

        var oldKeysToDrop: [String] = []
        for (oldKey, newKey) in moves {
            // Absent means a fresh install, or an interrupted run that already
            // dropped this one. Writing a default here would stamp over the new
            // key, so leave both alone.
            guard let oldValue = defaults.object(forKey: oldKey) else { continue }
            defaults.set(oldValue, forKey: newKey)
            oldKeysToDrop.append(oldKey)
        }

        defaults.set(true, forKey: migrationKey)
        for oldKey in oldKeysToDrop { defaults.removeObject(forKey: oldKey) }
    }

    /// Current color components, 0...255 (derived from HSB).
    var red: Double { rgb.r }
    var green: Double { rgb.g }
    var blue: Double { rgb.b }

    private var rgb: (r: Double, g: Double, b: Double) {
        let nsColor = NSColor(
            hue: CGFloat(hue),
            saturation: CGFloat(saturation),
            brightness: CGFloat(brightness),
            alpha: 1
        ).usingColorSpace(.sRGB) ?? .black
        return (Double(nsColor.redComponent) * 255,
                Double(nsColor.greenComponent) * 255,
                Double(nsColor.blueComponent) * 255)
    }

    /// sRGB hex ("#RRGGBB") for the current selection, cased per `uppercase`.
    var selectedHex: String {
        let format = uppercase ? "#%02X%02X%02X" : "#%02x%02x%02x"
        return String(format: format, byte(red), byte(green), byte(blue))
    }

    var selectedColor: Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
    }

    // MARK: GlancePlugin

    func refresh() async {
        // Nothing to auto-refresh; the tool is entirely user-driven.
    }

    func popoverSection() -> AnyView {
        AnyView(ColorsPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(ColorsSettings(plugin: self))
    }

    // MARK: Actions

    /// Opens the system eyedropper. On pick, loads the color into the live
    /// selection, copies its hex to the pasteboard, and records it in history.
    ///
    /// Sampling means clicking somewhere else on screen, which would read as a
    /// click outside the tool window and dismiss it mid-pick — so auto-close is
    /// suspended for the duration. The resume must run on every path, including
    /// cancellation, or the window could never be dismissed again.
    func pickColor() {
        lastError = nil
        ToolWindowManager.shared.suspendAutoClose()
        NSColorSampler().show { [weak self] color in
            MainActor.assumeIsolated {
                ToolWindowManager.shared.resumeAutoClose()
                guard let self, let color else { return } // nil = user cancelled
                guard let hex = ColorHex.hexString(from: color, uppercase: self.uppercase) else {
                    self.lastError = "Couldn't read that color"
                    return
                }
                self.recordPick(hex)
            }
        }
    }

    /// Loads a hex string into the live HSB selection.
    func select(hex: String) {
        guard let nsColor = ColorHex.color(fromHex: hex)?.usingColorSpace(.sRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Preserve hue when selecting a greyscale color (saturation 0 reports hue 0).
        if s > 0 { hue = Double(h) }
        saturation = Double(s)
        brightness = Double(b)
    }

    /// Selects a swatch and copies it, without adding a duplicate history entry
    /// (a recent one just moves back to the front).
    func selectSwatch(_ hex: String) {
        recordPick(hex)
    }

    /// Copies the current selection's hex to the general pasteboard.
    func copySelected() {
        copyToPasteboard(selectedHex)
    }

    /// Adds or removes the current color from the shared favorites list.
    func toggleFavorite() {
        ColorFavoritesStore.shared.toggle(selectedHex)
    }

    func clearHistory() {
        recentHexes = []
        persistRecents()
    }

    // MARK: Helpers

    private func recordPick(_ hex: String) {
        select(hex: hex)
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

    private func byte(_ component: Double) -> Int {
        Int((min(max(component, 0), 255)).rounded())
    }
}

// MARK: - Popover UI

private struct ColorsPopover: View {
    @Bindable var plugin: ColorsPlugin
    private let store = ColorFavoritesStore.shared

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

            // Current color + hex + actions.
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(plugin.selectedColor)
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

                // The hex code is the whole point of the tool — never let it
                // truncate, even in the narrow popover. Everything else gives
                // way to it first.
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.selectedHex)
                        .font(.body.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize()
                    Text("R \(Int(plugin.red))  G \(Int(plugin.green))  B \(Int(plugin.blue))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .layoutPriority(1)

                Spacer(minLength: 4)

                Button {
                    plugin.toggleFavorite()
                } label: {
                    Image(systemName: store.isFavorite(plugin.selectedHex) ? "star.fill" : "star")
                        .foregroundStyle(store.isFavorite(plugin.selectedHex) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(store.isFavorite(plugin.selectedHex) ? "Remove from favorites" : "Add to favorites")

                Button("Copy") { plugin.copySelected() }
                    .fixedSize()
            }

            // Saturation × brightness field + hue slider.
            VStack(spacing: 8) {
                SaturationBrightnessField(
                    hue: plugin.hue,
                    saturation: $plugin.saturation,
                    brightness: $plugin.brightness
                )
                .frame(height: 130)

                HueSlider(hue: $plugin.hue)
                    .frame(height: 18)
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

            Divider()
            Text("Favorites")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if store.favorites.isEmpty {
                Text("No favorites yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(store.favorites, id: \.self) { hex in
                        ColorSwatch(hex: hex) { plugin.select(hex: hex) }
                            .contextMenu {
                                Button("Remove", role: .destructive) { store.remove(hex) }
                            }
                    }
                }
            }
        }
    }
}

/// A 2D field: X = saturation (0→1), Y = brightness (1→0), tinted by `hue`.
/// Dragging the knob updates the bound saturation/brightness.
private struct SaturationBrightnessField: View {
    let hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double

    private let cornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // Base hue at full saturation/brightness, white overlay left→right,
                // black overlay top→bottom — the classic HSB square.
                Rectangle()
                    .fill(Color(hue: hue, saturation: 1, brightness: 1))
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.white, .white.opacity(0)],
                        startPoint: .leading, endPoint: .trailing))
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.black.opacity(0), .black],
                        startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.quaternary))
            .overlay(alignment: .topLeading) {
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 3))
                    .frame(width: 14, height: 14)
                    .offset(
                        x: CGFloat(saturation) * size.width - 7,
                        y: CGFloat(1 - brightness) * size.height - 7)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        saturation = clamp(Double(value.location.x / max(size.width, 1)))
                        brightness = clamp(1 - Double(value.location.y / max(size.height, 1)))
                    }
            )
        }
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

/// A horizontal hue spectrum slider (0→1) with a draggable knob.
private struct HueSlider: View {
    @Binding var hue: Double

    private var spectrum: [Color] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 12.0)
            .map { Color(hue: $0, saturation: 1, brightness: 1) }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Capsule()
                .fill(LinearGradient(colors: spectrum, startPoint: .leading, endPoint: .trailing))
                .overlay(Capsule().strokeBorder(.quaternary))
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(.black.opacity(0.25)))
                        .shadow(radius: 1)
                        .frame(width: geo.size.height, height: geo.size.height)
                        .offset(x: CGFloat(hue) * width - geo.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            hue = min(max(Double(value.location.x / max(width, 1)), 0), 1)
                        }
                )
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

private struct ColorsSettings: View {
    @Bindable var plugin: ColorsPlugin
    private let store = ColorFavoritesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Colors")
                .font(.headline)

            Toggle("Uppercase hex codes", isOn: $plugin.uppercase)

            Divider()

            Text("History")
                .font(.headline)
            Text("Keeps the last 12 picked colors.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear history", role: .destructive) {
                plugin.clearHistory()
            }
            .disabled(plugin.recentHexes.isEmpty)

            Divider()

            Text("Favorites")
                .font(.headline)
            Text("Star a color to keep it here.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear favorites", role: .destructive) {
                store.clear()
            }
            .disabled(store.favorites.isEmpty)
        }
    }
}
