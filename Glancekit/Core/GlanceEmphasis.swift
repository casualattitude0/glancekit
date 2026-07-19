import SwiftUI
import Observation

/// How much weight the user wants a glance to carry in the Smart Panel.
///
/// A glance reports its own `GlanceSignal.Priority` from what it measures — the
/// battery knows it's at 8%, the market glance knows a stock moved 4%. That's a
/// statement about the *machine*, not about the *person*: someone who lives in
/// their calendar and never looks at RAM wants the same two signals ranked
/// differently. Emphasis is that missing half — a per-glance nudge, applied on
/// top of what the glance reports, that shifts it one bucket up or down.
///
/// Deliberately three levels, not a slider: the ranking only has four priority
/// buckets, so a finer dial would promise precision the feed can't deliver.
enum GlanceEmphasis: Int, CaseIterable, Identifiable, Sendable {
    /// Push down a bucket — still shown, just below the things that matter more.
    case low = -1
    /// Take the glance at its word. The default for everything.
    case normal = 0
    /// Push up a bucket, so this glance leads the feed whenever it has anything
    /// to say.
    case high = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }
}

extension GlanceSignal.Priority {
    /// The priority the panel actually sorts and tints by: what the glance
    /// reported, nudged by the user's emphasis and clamped to the real buckets.
    ///
    /// Clamping — rather than widening the enum — keeps `urgent` meaning "top of
    /// the feed" for every glance. Emphasising an already-urgent signal can't
    /// invent a louder bucket to outrank the other urgent ones; it just holds
    /// its place.
    func emphasised(by emphasis: GlanceEmphasis) -> Self {
        let shifted = rawValue + emphasis.rawValue
        let clamped = min(max(shifted, Self.ambient.rawValue), Self.urgent.rawValue)
        return Self(rawValue: clamped) ?? self
    }
}

/// Per-glance emphasis, keyed by plugin id and persisted to `UserDefaults`.
///
/// Only non-`normal` levels are stored, so the backing dictionary stays empty
/// until the user actually changes something and an unknown (or newly added)
/// glance reads as `normal` for free.
@MainActor
@Observable
final class GlanceEmphasisStore {
    private let defaults = UserDefaults.standard
    private let key = "glancekit.glance.emphasis"

    /// plugin id → `GlanceEmphasis.rawValue`. Entries equal to `.normal` are
    /// removed rather than written, so `isCustomised` is a plain emptiness check.
    private var levels: [String: Int]

    init() {
        levels = (defaults.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }

    func emphasis(for id: String) -> GlanceEmphasis {
        levels[id].flatMap(GlanceEmphasis.init(rawValue:)) ?? .normal
    }

    func setEmphasis(_ emphasis: GlanceEmphasis, for id: String) {
        if emphasis == .normal {
            levels.removeValue(forKey: id)
        } else {
            levels[id] = emphasis.rawValue
        }
        persist()
    }

    /// True once anything has been moved off `normal` — drives the Reset button.
    var isCustomised: Bool { !levels.isEmpty }

    func resetAll() {
        levels.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(levels, forKey: key)
    }
}
