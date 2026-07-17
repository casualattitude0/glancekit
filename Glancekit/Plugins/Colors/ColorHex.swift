import AppKit

/// Conversion helpers between `NSColor` and hex strings, used for both
/// clipboard output and swatch rendering.
enum ColorHex {
    /// Converts a color to an sRGB hex string ("#RRGGBB"), clamping
    /// components into range. Returns nil if the color can't be represented
    /// in the sRGB color space.
    static func hexString(from color: NSColor, uppercase: Bool = true) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = clampedByte(srgb.redComponent)
        let g = clampedByte(srgb.greenComponent)
        let b = clampedByte(srgb.blueComponent)
        let format = uppercase ? "#%02X%02X%02X" : "#%02x%02x%02x"
        return String(format: format, r, g, b)
    }

    /// Parses a hex string ("#RRGGBB" or "RRGGBB") into an sRGB `NSColor`.
    static func color(fromHex hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// Integer 0–255 RGB components for display, in sRGB space.
    static func rgbComponents(from color: NSColor) -> (r: Int, g: Int, b: Int)? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return (clampedByte(srgb.redComponent), clampedByte(srgb.greenComponent), clampedByte(srgb.blueComponent))
    }

    private static func clampedByte(_ component: CGFloat) -> Int {
        Int((min(max(component, 0), 1) * 255).rounded())
    }
}
