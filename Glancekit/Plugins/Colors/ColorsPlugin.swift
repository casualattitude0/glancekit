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

    /// A real editing surface (the picker beside a list of color sets) earns a
    /// roomier standalone window than the default 360×520 — wide enough for the
    /// palette sidebar to sit LEFT of the picker. In the narrow menu-bar popover
    /// the same view collapses to a single column (see `ColorsPopover`).
    var preferredToolWindowSize: CGSize? { CGSize(width: 620, height: 560) }

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

// The same section renders in two very different containers: a narrow column in
// the menu-bar popover, and a wide standalone tool window (see
// `preferredToolWindowSize`). So it has two shapes, chosen by `ViewThatFits`:
//
//   • Two-pane — the color-set list (Favorites + user palettes) as a sidebar on
//     the LEFT beside the picker, when there's room (the standalone window).
//   • Single column — the picker on top with a compact set-picker menu, in the
//     narrow menu.
//
// `ViewThatFits` takes the widest layout that fits its container, so the section
// can never overflow the menu popover into a neighbouring glance.
private struct ColorsPopover: View {
    @Bindable var plugin: ColorsPlugin
    private let favorites = ColorFavoritesStore.shared
    private let palettes = ColorPaletteStore.shared

    var body: some View {
        ViewThatFits(in: .horizontal) {
            twoPane
            singleColumn
        }
    }

    // MARK: Layouts

    private var twoPane: some View {
        HStack(alignment: .top, spacing: 14) {
            PaletteSidebar(plugin: plugin)
                .frame(width: 168)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                picker
                Divider()
                selectedSetSection
                if !plugin.recentHexes.isEmpty {
                    Divider()
                    recentSection
                }
            }
            .frame(minWidth: 300)
        }
    }

    private var singleColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            picker
            Divider()
            // No room for a sidebar here — the set is chosen from a menu instead.
            HStack {
                Text("Set")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                PaletteMenu(plugin: plugin)
            }
            selectedSetSection
            if !plugin.recentHexes.isEmpty {
                Divider()
                recentSection
            }
        }
    }

    // MARK: Picker (shared by both layouts)

    @ViewBuilder
    private var picker: some View {
        Button {
            plugin.pickColor()
        } label: {
            Label("Pick color", systemImage: "eyedropper")
                .frame(maxWidth: .infinity)
        }

        if let err = plugin.lastError {
            Label(err, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(GlanceStyle.warning)
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
                Image(systemName: favorites.isFavorite(plugin.selectedHex) ? "star.fill" : "star")
                    .foregroundStyle(favorites.isFavorite(plugin.selectedHex) ? GlanceStyle.highlight : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(favorites.isFavorite(plugin.selectedHex) ? "Remove from favorites" : "Add to favorites")

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
    }

    // MARK: Selected set (favorites or the chosen palette)

    /// Adaptive columns fill the panel width evenly and re-flow with it, so the
    /// grid never leaves a ragged gap on the right the way fixed columns did.
    private let swatchColumns = [GridItem(.adaptive(minimum: 30, maximum: 46), spacing: 6)]

    private func isCurrent(_ hex: String) -> Bool {
        hex.caseInsensitiveCompare(plugin.selectedHex) == .orderedSame
    }

    @ViewBuilder
    private var selectedSetSection: some View {
        switch palettes.selection {
        case .favorites:
            setHeader(title: "Favorites",
                      count: favorites.favorites.count,
                      canAdd: !favorites.isFavorite(plugin.selectedHex)) {
                favorites.add(plugin.selectedHex)
            }
            swatchGrid(favorites.favorites,
                       emptyText: "Star a color, or use Add, to keep it here.") { hex in
                favorites.remove(hex)
            }

        case .palette(let id):
            let palette = palettes.palette(id)
            setHeader(title: palette?.name ?? "Palette",
                      count: palette?.colors.count ?? 0,
                      canAdd: !(palette.map { palettes.contains(plugin.selectedHex, in: $0.id) } ?? true)) {
                palettes.addColor(plugin.selectedHex, to: id)
            }
            swatchGrid(palette?.colors ?? [],
                       emptyText: "Add the current color with the Add button.") { hex in
                palettes.removeColor(hex, from: id)
            }
        }
    }

    /// A set title (with count) and an "add current color" button on the right,
    /// tinted to the live color so it reads as "put *this* in the set".
    private func setHeader(title: String, count: Int, canAdd: Bool,
                           add: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            sectionLabel(title, count: count)
            Spacer()
            Button(action: add) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(plugin.selectedColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(.quaternary))
                    Text("Add")
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(!canAdd)
            .help(canAdd ? "Add the current color to this set" : "Already in this set")
        }
    }

    /// A grid of swatches with tap-to-select and context-menu remove, or a
    /// placeholder line when empty. The live color gets an accent ring so it's
    /// easy to spot which swatch is currently loaded.
    @ViewBuilder
    private func swatchGrid(_ hexes: [String], emptyText: String,
                            remove: @escaping (String) -> Void) -> some View {
        if hexes.isEmpty {
            Text(emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            LazyVGrid(columns: swatchColumns, spacing: 6) {
                ForEach(hexes, id: \.self) { hex in
                    ColorSwatch(hex: hex, isSelected: isCurrent(hex), fillWidth: true) {
                        plugin.select(hex: hex)
                    }
                    .contextMenu {
                        Button("Copy") { plugin.selectSwatch(hex) }
                        Button("Remove", role: .destructive) { remove(hex) }
                    }
                }
            }
        }
    }

    // MARK: Recent

    // Recents are time-ordered, so a single horizontal strip (newest at the
    // left) reads as a timeline — a wrapping grid loses that order cue.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Recent", count: plugin.recentHexes.count)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(plugin.recentHexes, id: \.self) { hex in
                        ColorSwatch(hex: hex, isSelected: isCurrent(hex)) {
                            plugin.selectSwatch(hex)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// A section title with a subtle count chip.
    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Palette sidebar (wide layout)

/// The left-hand list of color sets: Favorites (built-in, always first) followed
/// by the user's palettes, with add/remove/rename controls at the foot.
private struct PaletteSidebar: View {
    @Bindable var plugin: ColorsPlugin
    private let favorites = ColorFavoritesStore.shared
    private let palettes = ColorPaletteStore.shared

    /// The palette whose name field is currently open for editing, if any, and
    /// the working copy of its name. A draft (rather than binding straight to
    /// the store) lets Escape/empty-input fall back to the existing name.
    @State private var renamingID: UUID?
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    /// The palette awaiting a delete confirmation, if any. Deleting a set throws
    /// away every color in it, so both delete paths route through a prompt.
    @State private var pendingDeleteID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sets")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 2) {
                    row(title: "Favorites",
                        systemImage: "star.fill",
                        count: favorites.favorites.count,
                        isSelected: palettes.selection == .favorites) {
                        palettes.selection = .favorites
                    }

                    ForEach(palettes.palettes) { palette in
                        paletteRow(palette)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                // New set: create, select, and drop straight into an
                // auto-focused rename with the default name preselected — type
                // and it's replaced, or click away / press ⏎ to keep it. No
                // mandatory field-click first.
                Button(action: addAndRename) {
                    Label("New set", systemImage: "plus")
                        .font(.caption)
                }
                .help("New color set")

                Spacer()

                Button {
                    if case .palette(let id) = palettes.selection {
                        pendingDeleteID = id
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(palettes.selection == .favorites)
                .help("Delete the selected set")
            }
            .buttonStyle(.borderless)
        }
        .confirmationDialog(
            deletePrompt,
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID { palettes.removePalette(id) }
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        }
        // The dialog is a separate panel: presenting it takes key away from the
        // floating tool window, which would auto-close it (same problem the
        // eyedropper has). Suspend click-outside dismissal while it's up — same
        // bracket ColorsPlugin.pickColor() uses — so the window survives long
        // enough for the button action to run, then re-focus it on dismiss.
        .onChange(of: pendingDeleteID) { _, id in
            if id != nil {
                ToolWindowManager.shared.suspendAutoClose()
            } else {
                ToolWindowManager.shared.resumeAutoClose()
            }
        }
    }

    /// Names the set in the confirmation so it's clear which one is going.
    private var deletePrompt: String {
        guard let id = pendingDeleteID, let palette = palettes.palette(id) else {
            return "Delete this set?"
        }
        let n = palette.colors.count
        let colors = n == 1 ? "1 color" : "\(n) colors"
        return "Delete “\(palette.name)”? Its \(colors) will be removed."
    }

    @ViewBuilder
    private func paletteRow(_ palette: ColorPalette) -> some View {
        if renamingID == palette.id {
            // Placeholder shows the current name, so an empty draft still reads
            // sensibly and committing empty keeps that name (see commitRename).
            TextField(palette.name, text: $draftName)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .focused($nameFieldFocused)
                .onSubmit(commitRename)
                .onExitCommand { renamingID = nil }        // Escape: cancel
                .onChange(of: nameFieldFocused) { _, focused in
                    // Clicking anywhere else commits, matching Finder's New Folder.
                    if !focused && renamingID == palette.id { commitRename() }
                }
        } else {
            row(title: palette.name,
                systemImage: "paintpalette",
                count: palette.colors.count,
                isSelected: palettes.selection == .palette(palette.id)) {
                palettes.selection = .palette(palette.id)
            }
            .contextMenu {
                Button("Rename") { beginRename(palette) }
                Button("Delete", role: .destructive) { pendingDeleteID = palette.id }
            }
        }
    }

    private func addAndRename() {
        let id = palettes.addPalette()
        draftName = ""
        renamingID = id
        nameFieldFocused = true
    }

    private func beginRename(_ palette: ColorPalette) {
        draftName = palette.name
        renamingID = palette.id
        nameFieldFocused = true
    }

    private func commitRename() {
        defer { renamingID = nil }
        guard let id = renamingID else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty means "leave it": a fresh set keeps its "Palette N" default.
        if !trimmed.isEmpty { palettes.rename(id, to: trimmed) }
    }

    private func row(title: String, systemImage: String, count: Int,
                     isSelected: Bool, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
            }
            .foregroundStyle(isSelected ? Color.white : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Palette menu (narrow layout)

/// The set chooser for the single-column popover, where there's no room for the
/// sidebar. Picking "New set…" both creates and selects one.
private struct PaletteMenu: View {
    @Bindable var plugin: ColorsPlugin
    private let palettes = ColorPaletteStore.shared

    private var currentTitle: String {
        switch palettes.selection {
        case .favorites: return "Favorites"
        case .palette(let id): return palettes.palette(id)?.name ?? "Palette"
        }
    }

    var body: some View {
        Menu(currentTitle) {
            Button("Favorites") { palettes.selection = .favorites }
            if !palettes.palettes.isEmpty {
                Divider()
                ForEach(palettes.palettes) { palette in
                    Button(palette.name) { palettes.selection = .palette(palette.id) }
                }
            }
            Divider()
            Button("New set…") { palettes.addPalette() }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
    /// Draws an accent ring — used to mark the swatch matching the live color.
    var isSelected: Bool = false
    /// Fill the enclosing grid cell's width (fixed square otherwise).
    var fillWidth: Bool = false
    var height: CGFloat = 28
    let action: () -> Void

    private let cornerRadius: CGFloat = 6

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(swatchColor)
                .frame(width: fillWidth ? nil : height, height: height)
                .frame(maxWidth: fillWidth ? .infinity : nil)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.black.opacity(0.12),
                            lineWidth: isSelected ? 2 : 1)
                )
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
        SettingsPage("Colors") {
            SettingsToggleRow("Uppercase hex codes", isOn: $plugin.uppercase)

            Divider()

            SettingsSectionHeader("History")
            SettingsHelp("Keeps the last 12 picked colors.")
            Button("Clear history", role: .destructive) {
                plugin.clearHistory()
            }
            .disabled(plugin.recentHexes.isEmpty)

            Divider()

            SettingsSectionHeader("Favorites")
            SettingsHelp("Star a color to keep it here.")
            Button("Clear favorites", role: .destructive) {
                store.clear()
            }
            .disabled(store.favorites.isEmpty)
        }
    }
}
