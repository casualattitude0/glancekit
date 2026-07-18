import Foundation
import Observation

/// Remembers what the Smart Panel showed last time it closed, so the next time
/// it opens it can point out **what changed** — a card that wasn't there before,
/// or one whose reading moved. That's a big part of what makes the feed feel
/// aware rather than a static status list.
///
/// The baseline is committed when the panel disappears and compared against on
/// the next appearance, so a delta reflects "since you last looked", not the
/// churn of a single viewing session. Persisted to `UserDefaults` so it survives
/// relaunches.
@MainActor
@Observable
final class SmartPanelHistory {

    /// What one glance was showing at the last commit.
    private struct Snapshot: Codable {
        var headline: String
        var score: Double
    }

    /// How a glance's current signal compares to the last time the panel closed.
    struct Delta {
        /// The glance had no card at the last close but has one now.
        var isNew: Bool
        /// The glance's headline reading changed since the last close.
        var changed: Bool

        static let none = Delta(isNew: false, changed: false)
    }

    private var baseline: [String: Snapshot] = [:]
    /// Until the first commit there's nothing to compare against, so everything
    /// would look "new". Suppress deltas entirely until we have a real baseline.
    private var hasBaseline: Bool = false

    private let key = "glancekit.menupanel.history"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Snapshot].self, from: data) {
            baseline = decoded
            hasBaseline = true
        }
    }

    /// How this glance's current signal compares to the last close.
    func delta(id: String, headline: String, score: Double) -> Delta {
        guard hasBaseline else { return .none }
        guard let previous = baseline[id] else { return Delta(isNew: true, changed: false) }
        return Delta(isNew: false, changed: previous.headline != headline)
    }

    /// Record the currently-shown cards as the new baseline. Call when the panel
    /// closes so the next open compares against what the user actually last saw.
    func commit(_ entries: [(id: String, headline: String, score: Double)]) {
        baseline = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, Snapshot(headline: $0.headline, score: $0.score))
        })
        hasBaseline = true
        if let data = try? JSONEncoder().encode(baseline) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
