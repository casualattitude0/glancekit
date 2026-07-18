import SwiftUI

/// A glance's self-reported relevance for the **Smart Panel** — the dynamic
/// menu-bar layout that surfaces the glances that need attention right now
/// instead of showing every enabled glance in a fixed row.
///
/// A glance computes this from the state it already holds after `refresh()`
/// (see `GlancePlugin.currentSignal()`), and the panel ranks the signals
/// across all enabled glances. Returning `nil` from `currentSignal()` means
/// "nothing worth surfacing right now" — the default for glances that have no
/// time-sensitive story to tell.
struct GlanceSignal {

    /// How much the glance is asking to be seen. Ordered, so the panel can sort
    /// by it: `urgent` outranks `elevated` outranks `normal` outranks `ambient`.
    enum Priority: Int, Comparable {
        /// Filler: only shown when the feed has room left over, so a quiet Mac
        /// still shows something useful rather than an empty panel.
        case ambient
        /// Routine but worth a glance (e.g. a small market move).
        case normal
        /// Notable — something changed or is worth a look (unread notifications,
        /// a big mover, a running timer).
        case elevated
        /// Needs attention now (memory pressure, low battery, failing CI).
        case urgent

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// A compact visual the card draws to the right of the text, so a reading is
    /// legible without opening the glance.
    enum Accessory {
        case none
        /// A 0…1 filled bar — memory pressure, disk usage, battery level.
        case gauge(Double)
        /// A tiny line chart — an intraday stock series, coloured by direction.
        case sparkline([Double], up: Bool)
    }

    /// An inline button the card offers, so the obvious next step is one click
    /// away without opening the glance (Join a meeting, pause a timer, …).
    struct QuickAction {
        let title: String
        let systemImage: String
        let run: @MainActor () -> Void
    }

    /// The urgency bucket this signal sits in.
    var priority: Priority

    /// A finer-grained rank used to break ties *within* a priority (e.g. RAM
    /// percentage, notification count, |percent change|). Higher sorts first.
    /// Also read by the panel's change-detection to tell rising from falling.
    var score: Double

    /// The compact primary line shown on the card, e.g. "Memory 92% · 14.8G / 16G".
    var headline: String

    /// An optional secondary line shown in a dimmer style beneath the headline.
    var detail: String?

    /// An SF Symbol override for the card's icon. Falls back to the glance's own
    /// `iconSystemName` when nil.
    var systemImage: String?

    /// An accent colour for the card's icon and leading stripe. Falls back to a
    /// neutral tint derived from the priority when nil.
    var tint: Color?

    /// A compact visual (gauge / sparkline) drawn on the card.
    var accessory: Accessory

    /// An inline action button the card offers.
    var quickAction: QuickAction?

    init(
        priority: Priority,
        score: Double = 0,
        headline: String,
        detail: String? = nil,
        systemImage: String? = nil,
        tint: Color? = nil,
        accessory: Accessory = .none,
        quickAction: QuickAction? = nil
    ) {
        self.priority = priority
        self.score = score
        self.headline = headline
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory
        self.quickAction = quickAction
    }
}
