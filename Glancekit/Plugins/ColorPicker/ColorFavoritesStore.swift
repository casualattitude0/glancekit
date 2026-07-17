import SwiftUI
import Observation

/// Shared favorite-colors list backing both the Color Picker and Color Palette
/// glances. A single, app-wide favorites list keeps a color you star in one
/// tool visible in the other.
///
/// Colors are stored as sRGB hex strings ("#RRGGBB", uppercase) in
/// `UserDefaults`. The store is a singleton so every glance mutates the same
/// list and SwiftUI re-renders everywhere via `@Observable`.
@MainActor
@Observable
final class ColorFavoritesStore {
    static let shared = ColorFavoritesStore()

    private let favoritesKey = "glancekit.colors.favorites"
    private let maxFavorites = 60

    /// Most-recently-added-first list of favorite hex strings ("#RRGGBB").
    private(set) var favorites: [String]

    private init() {
        favorites = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
    }

    /// Normalizes any hex input to the canonical stored form ("#RRGGBB"),
    /// or nil if it isn't a valid 6-digit hex color.
    private func normalized(_ hex: String) -> String? {
        guard let color = ColorHex.color(fromHex: hex) else { return nil }
        return ColorHex.hexString(from: color, uppercase: true)
    }

    func isFavorite(_ hex: String) -> Bool {
        guard let key = normalized(hex) else { return false }
        return favorites.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// Adds a color to favorites (no-op if already present). Newest first.
    func add(_ hex: String) {
        guard let key = normalized(hex), !isFavorite(key) else { return }
        var updated = favorites
        updated.insert(key, at: 0)
        if updated.count > maxFavorites { updated = Array(updated.prefix(maxFavorites)) }
        favorites = updated
        persist()
    }

    func remove(_ hex: String) {
        guard let key = normalized(hex) else { return }
        favorites.removeAll { $0.caseInsensitiveCompare(key) == .orderedSame }
        persist()
    }

    /// Adds the color if absent, removes it if present. Returns the new state.
    @discardableResult
    func toggle(_ hex: String) -> Bool {
        if isFavorite(hex) {
            remove(hex)
            return false
        } else {
            add(hex)
            return true
        }
    }

    func clear() {
        favorites = []
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(favorites, forKey: favoritesKey)
    }
}
