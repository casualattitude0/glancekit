import SwiftUI
import AppKit
import Observation

/// Color palette / favorites glance.
///
/// Presents a self-contained inline palette — a spectrum of preset swatches
/// plus a saturation/brightness field with a hue slider — so the user can dial
/// in any color without leaving the popover. (A menu-bar/accessory app can't
/// reliably surface the system `NSColorPanel`, so the palette is drawn
/// in-popover instead.) The current color's sRGB hex can be copied or starred
/// into the app-wide favorites list shared with the Color Picker glance.
///
/// - Menu-bar: contributes nothing (`menuBarSummary` is nil) — popover-only.
/// - Popover: an HSB saturation/brightness field + hue slider, a preset
///   palette grid, the current color shown large with hex + copy + favorite
///   controls, and a grid of favorite swatches.
@MainActor
@Observable
final class ColorPalettePlugin: GlancePlugin {
    nonisolated var id: String { "colorpalette" }
    nonisolated var title: String { "Color Palette" }
    nonisolated var iconSystemName: String { "paintpalette" }
    var refreshInterval: TimeInterval { 0 }
    var menuBarSummary: String? { nil }

    /// Current color in HSB, each component 0...1. HSB is the source of truth
    /// so the 2D field (saturation × brightness) and hue slider map directly.
    var hue: Double = 0.58
    var saturation: Double = 1
    var brightness: Double = 1

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

    /// Curated preset palette shown as tappable swatches.
    let presets: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#30B0C7",
        "#0091FF", "#5856D6", "#AF52DE", "#FF2D55", "#A2845E", "#8E8E93",
        "#000000", "#3A3A3C", "#636366", "#8E8E93", "#C7C7CC", "#FFFFFF",
    ]

    /// sRGB hex ("#RRGGBB", uppercase) for the current components.
    var selectedHex: String {
        String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    var selectedColor: Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
    }

    // MARK: GlancePlugin

    func refresh() async {
        // Nothing to auto-refresh; the palette is user-driven.
    }

    func popoverSection() -> AnyView {
        AnyView(ColorPalettePopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(ColorPaletteSettings(plugin: self))
    }

    // MARK: Actions

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

    /// Copies the current hex to the general pasteboard.
    func copySelected() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedHex, forType: .string)
    }

    /// Adds or removes the current color from the shared favorites list.
    func toggleFavorite() {
        ColorFavoritesStore.shared.toggle(selectedHex)
    }

    // MARK: Helpers

    private func byte(_ component: Double) -> Int {
        Int((min(max(component, 0), 255)).rounded())
    }
}

// MARK: - Popover UI

private struct ColorPalettePopover: View {
    @Bindable var plugin: ColorPalettePlugin
    private let store = ColorFavoritesStore.shared

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Current color + hex + actions.
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(plugin.selectedColor)
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.selectedHex)
                        .font(.body.monospaced().weight(.semibold))
                    Text("R \(Int(plugin.red))  G \(Int(plugin.green))  B \(Int(plugin.blue))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                Spacer()

                Button {
                    plugin.toggleFavorite()
                } label: {
                    Image(systemName: store.isFavorite(plugin.selectedHex) ? "star.fill" : "star")
                        .foregroundStyle(store.isFavorite(plugin.selectedHex) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(store.isFavorite(plugin.selectedHex) ? "Remove from favorites" : "Add to favorites")

                Button("Copy") { plugin.copySelected() }
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

            Divider()
            Text("Palette")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(plugin.presets, id: \.self) { hex in
                    PaletteSwatch(hex: hex) { plugin.select(hex: hex) }
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
                        PaletteSwatch(hex: hex) { plugin.select(hex: hex) }
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

private struct PaletteSwatch: View {
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

private struct ColorPaletteSettings: View {
    @Bindable var plugin: ColorPalettePlugin
    private let store = ColorFavoritesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Color Palette")
                .font(.headline)

            Text("Favorites are shared with the Color Picker glance.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Clear favorites", role: .destructive) {
                store.clear()
            }
            .disabled(store.favorites.isEmpty)
        }
    }
}
