import SwiftUI

/// Shared visual vocabulary for glance *content* — the panels, strips and hero
/// readouts every plugin renders — so twenty plugins read as one surface instead
/// of each inventing its own type sizes and status colours.
///
/// This is the content-side companion to `SettingsKit`. Like SettingsKit, it does
/// **not** replace SwiftUI's native scale: panels keep using `.caption`, `.body`,
/// `.secondary`, `.monospacedDigit()` — those already unify the surface. GlanceStyle
/// only names the two things the native scale leaves you spelling by hand:
///
/// - **Sub-caption sizes.** `.caption2` bottoms out near 11pt, but the dense strips
///   (a world-clock grid, a stock badge) want 8–10pt. Those were `.system(size: 8/9/10)`
///   copied into every plugin; now they are three named roles that still compose with
///   `.weight(_:)`, `.monospacedDigit()` and `.monospaced()` at the call site.
/// - **Hero readouts.** The one big rounded number a panel is built around — a
///   temperature, a countdown, a battery percent — was `.system(size: 30/40/44, …)`.
///   Now it is one ``hero(_:weight:)`` role: rounded, monospaced-digit, one look.
///
/// It also names the **status colours** that were spelled `.orange` / `.red` /
/// `.green` / `.yellow` inline across the plugins, so "a warning", "a loss" or "a
/// live/OK state" reads the same everywhere and reskins from one place.
///
/// **Out of scope, on purpose.** Domain colour rules that legitimately differ live in
/// their own types and are left alone — most importantly `Market.tint(rising:)`, where
/// a Taiwan ticker paints a *rise* red. Editor content sizes (the Notes monospace body)
/// and Markdown heading scales are their own typographic systems, not glance chrome.
/// And spacing stays per-layout: these panels are tuned for information density the way
/// `SettingsMetrics` is tuned for the Settings rhythm, so GlanceStyle names type and
/// colour, not gaps.
enum GlanceStyle {

    // MARK: - Type roles (below the native scale)

    /// 8pt — the densest strip labels and micro-badges.
    static let micro = Font.system(size: 8)
    /// 9pt — compact secondary rows.
    static let mini = Font.system(size: 9)
    /// 10pt — compact primary rows.
    static let compact = Font.system(size: 10)

    /// The single large readout a panel is built around: a temperature, a timer, a
    /// percent. Rounded and monospaced-digit are the shared look; `size` and `weight`
    /// stay per-panel because a battery gauge and a countdown want different heft.
    static func hero(_ size: CGFloat = 40, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    // MARK: - Status colours (semantic, theme-following)

    /// A good / complete / live / gaining state — was inline `.green`.
    static let positive = Color.green
    /// A loss / error / destructive state — was inline `.red`.
    static let negative = Color.red
    /// A caution / overdue / stale / needs-attention state — was inline `.orange`.
    static let warning = Color.orange
    /// A favourite / starred / spotlighted mark (a star, a tip bulb) — was inline `.yellow`.
    static let highlight = Color.yellow
}
