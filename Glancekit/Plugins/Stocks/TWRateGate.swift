import Foundation

/// The single choke point for every request this glance makes to a Taiwan
/// exchange host.
///
/// twstock's README states the limit plainly: **3 requests per 5 seconds, and
/// exceeding it gets you banned.** A ban is IP-wide and not something we can
/// apologise our way out of from inside a menu-bar app, so the budget is
/// enforced here rather than trusted to each call site. Realtime polling and
/// the after-close history sweep both queue through the same gate, which is the
/// point — independently well-behaved callers can still add up to a ban.
///
/// On top of the shared budget, MIS gets a per-endpoint floor: its own response
/// carries `userDelay: 5000`, the server telling us how often it expects to be
/// asked. We honour that even though our actual cadence (20s) is far slower.
actor TWRateGate {
    static let shared = TWRateGate()

    /// Endpoints with their own minimum spacing, beyond the shared budget.
    enum Kind {
        case mis        // mis.twse.com.tw realtime — server-declared 5s floor
        case history    // twse/tpex daily bars — shared budget only

        var minimumGap: TimeInterval { self == .mis ? 5 : 0 }
    }

    private let maxRequests = 3
    private let window: TimeInterval = 5

    /// Minimum spacing between *any* two requests, on top of the window cap.
    ///
    /// Without it the gate lets three requests go instantly, waits, then
    /// releases three more the moment the window rolls — which puts six
    /// requests inside a hair over five seconds and sits exactly on the edge of
    /// the documented limit. Spacing them out costs nothing (we're never in a
    /// hurry) and keeps a comfortable margin from a ban we cannot undo.
    private var minimumSpacing: TimeInterval { window / Double(maxRequests) }

    private var recent: [Date] = []
    private var lastAny: Date?
    private var lastByKind: [String: Date] = [:]

    // Injected so the test harness can drive this with a fake clock instead of
    // spending real seconds proving the budget holds.
    private let now: () -> Date
    private let sleeper: (TimeInterval) async -> Void

    init(now: @escaping () -> Date = Date.init,
         sleeper: @escaping (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         }) {
        self.now = now
        self.sleeper = sleeper
    }

    /// Waits until a request of this kind is within budget, then records it.
    /// Callers must make the request immediately after this returns.
    func acquire(_ kind: Kind) async {
        let key = String(describing: kind)
        while true {
            let t = now()
            recent.removeAll { t.timeIntervalSince($0) >= window }

            var wait: TimeInterval = 0
            if recent.count >= maxRequests, let oldest = recent.first {
                wait = max(wait, window - t.timeIntervalSince(oldest))
            }
            if let last = lastAny {
                wait = max(wait, minimumSpacing - t.timeIntervalSince(last))
            }
            let gap = kind.minimumGap
            if gap > 0, let last = lastByKind[key] {
                wait = max(wait, gap - t.timeIntervalSince(last))
            }

            // Compare against a tolerance, not zero. Sleeping for the exact
            // remaining interval leaves a sub-nanosecond residue from the
            // floating-point round trip, and a "wait" that small doesn't move
            // the clock at all — so a strict `> 0` test spins forever instead
            // of proceeding. A millisecond of slack is nothing against a
            // five-second budget.
            //
            // No await between this check and the bookkeeping below, so two
            // callers can't both slip through on the same free slot.
            if wait <= 0.001 {
                recent.append(t)
                lastAny = t
                lastByKind[key] = t
                return
            }
            await sleeper(wait)
        }
    }
}
