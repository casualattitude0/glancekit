import SwiftUI

/// A mirror of the app's `GlanceStyle` (Glancekit/UI/GlanceStyle.swift), kept
/// here because the widget runs in its own sandboxed process and deliberately
/// shares no code or storage with the app — the same reason `WidgetFetchers`
/// re-declares its own model types. Keep the two in sync: same role names, same
/// values, so a widget and its in-app panel read as one surface.
///
/// See the app copy for the full rationale. In short: this names the sub-caption
/// sizes and the one hero readout that SwiftUI's native scale doesn't give, plus
/// the status colours that were otherwise spelled `.orange` inline.
enum GlanceStyle {

    // MARK: Type roles (below the native scale)

    static let micro = Font.system(size: 8)
    static let mini = Font.system(size: 9)
    static let compact = Font.system(size: 10)

    /// The single large readout a widget is built around (a temperature).
    static func hero(_ size: CGFloat = 40, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    // MARK: Status colours (semantic, theme-following)

    static let positive = Color.green
    static let negative = Color.red
    static let warning = Color.orange
    static let highlight = Color.yellow
}
