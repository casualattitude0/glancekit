import SwiftUI
import Observation

/// One named color set — a "palette".
///
/// Colors are sRGB hex strings ("#RRGGBB", uppercase) in insertion order, so a
/// palette reads the way the user built it rather than being re-sorted under
/// them. The `id` is stable across renames, which is what selection and
/// persistence key off of (the name is free to change).
struct ColorPalette: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// sRGB hex strings ("#RRGGBB"), newest-added last (insertion order).
    var colors: [String]

    init(id: UUID = UUID(), name: String, colors: [String] = []) {
        self.id = id
        self.name = name
        self.colors = colors
    }
}

/// The app-wide collection of user color sets, backing the Colors glance's
/// left-hand palette list.
///
/// This is the sibling of `ColorFavoritesStore`: favorites is the single,
/// universal "starred" set that the ★ button toggles into, and lives on its own
/// so the star means the same thing from every surface. Palettes are the
/// *named, multiple* sets a user curates by hand — a "Brand", a "Warm greys",
/// whatever — and there can be any number of them. The Colors popover lists
/// favorites first (built-in, always present) and then these.
///
/// Persisted as one JSON blob under a single key, rather than a key per palette:
/// the whole list is small, always loaded and saved together, and one blob keeps
/// order and selection trivially consistent. The store is a singleton so every
/// surface mutates the same list and SwiftUI re-renders everywhere via
/// `@Observable`.
@MainActor
@Observable
final class ColorPaletteStore {
    static let shared = ColorPaletteStore()

    private let palettesKey = "glancekit.colors.palettes"
    private let selectionKey = "glancekit.colors.selectedPalette"
    private let maxColorsPerPalette = 60

    /// Which set the popover is showing. Favorites is a built-in set that isn't
    /// in `palettes`, so selection is an enum rather than an optional id.
    enum Selection: Equatable {
        case favorites
        case palette(UUID)
    }

    /// User palettes, in display order (top to bottom in the sidebar).
    private(set) var palettes: [ColorPalette]

    /// The currently shown set. Persisted so the tool reopens where it left off.
    var selection: Selection {
        didSet { persistSelection() }
    }

    private init() {
        // Compute into locals first: with `@Observable`, reading `self.palettes`
        // is a getter call, which Swift forbids until every stored property is
        // initialized — so `loadSelection` takes the local, not the property.
        let loaded = Self.loadPalettes(forKey: palettesKey)
        palettes = loaded
        selection = Self.loadSelection(forKey: selectionKey, palettes: loaded)
    }

    // MARK: - Palette lifecycle

    /// Creates an empty palette, appends it, selects it, and returns its id so
    /// the caller can immediately drop the user into a rename.
    @discardableResult
    func addPalette(name: String? = nil) -> UUID {
        let palette = ColorPalette(name: name ?? defaultName())
        palettes.append(palette)
        selection = .palette(palette.id)
        persistPalettes()
        return palette.id
    }

    func removePalette(_ id: UUID) {
        guard let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        palettes.remove(at: index)
        // If the shown set is the one going away, fall back to a neighbour so the
        // main panel is never pointing at a palette that no longer exists.
        if selection == .palette(id) {
            selection = palettes.indices.contains(index)
                ? .palette(palettes[index].id)
                : (palettes.last.map { .palette($0.id) } ?? .favorites)
        }
        persistPalettes()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        palettes[index].name = trimmed.isEmpty ? defaultName() : trimmed
        persistPalettes()
    }

    // MARK: - Colors within a palette

    /// Appends a color to the palette (no-op if it's already there — a set holds
    /// each color once). Normalizes to canonical "#RRGGBB".
    func addColor(_ hex: String, to id: UUID) {
        guard let key = Self.normalized(hex),
              let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        guard !palettes[index].colors.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) else { return }
        palettes[index].colors.append(key)
        if palettes[index].colors.count > maxColorsPerPalette {
            palettes[index].colors.removeFirst(palettes[index].colors.count - maxColorsPerPalette)
        }
        persistPalettes()
    }

    func removeColor(_ hex: String, from id: UUID) {
        guard let key = Self.normalized(hex),
              let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        palettes[index].colors.removeAll { $0.caseInsensitiveCompare(key) == .orderedSame }
        persistPalettes()
    }

    func palette(_ id: UUID) -> ColorPalette? {
        palettes.first { $0.id == id }
    }

    func contains(_ hex: String, in id: UUID) -> Bool {
        guard let key = Self.normalized(hex), let palette = palette(id) else { return false }
        return palette.colors.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
    }

    // MARK: - Persistence

    private func persistPalettes() {
        guard let data = try? JSONEncoder().encode(palettes) else { return }
        UserDefaults.standard.set(data, forKey: palettesKey)
    }

    private func persistSelection() {
        let raw: String
        switch selection {
        case .favorites: raw = "favorites"
        case .palette(let id): raw = id.uuidString
        }
        UserDefaults.standard.set(raw, forKey: selectionKey)
    }

    private static func loadPalettes(forKey key: String) -> [ColorPalette] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ColorPalette].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func loadSelection(forKey key: String, palettes: [ColorPalette]) -> Selection {
        guard let raw = UserDefaults.standard.string(forKey: key), raw != "favorites",
              let id = UUID(uuidString: raw),
              palettes.contains(where: { $0.id == id }) else {
            return .favorites
        }
        return .palette(id)
    }

    // MARK: - Helpers

    /// The next "Palette N" name that isn't already taken, so a run of Add
    /// clicks yields Palette 1, Palette 2, … instead of colliding.
    private func defaultName() -> String {
        let existing = Set(palettes.map(\.name))
        var n = palettes.count + 1
        while existing.contains("Palette \(n)") { n += 1 }
        return "Palette \(n)"
    }

    /// Canonical stored form ("#RRGGBB"), or nil if not a valid 6-digit hex.
    private static func normalized(_ hex: String) -> String? {
        guard let color = ColorHex.color(fromHex: hex) else { return nil }
        return ColorHex.hexString(from: color, uppercase: true)
    }
}
