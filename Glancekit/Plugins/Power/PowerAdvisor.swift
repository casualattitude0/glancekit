import Foundation

/// Turns the raw battery snapshot plus the rolling charge history into a single
/// "should I plug in / unplug right now?" recommendation.
///
/// Three inputs shape every answer:
/// - **Usage frequency** — how fast this Mac actually drains (%/hour) and how
///   often it gets charged, learned from `PowerPlugin.history`. A machine losing
///   30 %/h needs to be told to plug in far earlier than one losing 5 %/h.
/// - **Battery health** — a degraded cell holds less than its percentage claims
///   and sags harder under load, so the "plug in" floor is raised.
/// - **Temperature** — charging a hot cell is the single worst thing for its
///   lifespan, so heat overrides any "top it up" advice.
///
/// Everything here is pure: no IOKit, no UserDefaults, no UI. That makes the
/// whole decision table testable from a plain `swiftc` harness.
enum PowerAdvisor {

    // MARK: - Usage profile (learned from history)

    /// What the recent charge history says about how this Mac gets used.
    struct UsageProfile {
        /// Observed discharge rate in percent-per-hour over the most recent
        /// uninterrupted on-battery stretch. `nil` until there is enough data.
        var drainPerHour: Double?
        /// Roughly how many charge sessions happen per day, derived from the
        /// long-horizon charge-session log (not the sparkline samples, which
        /// span only ~1 hour). `nil` when the log is too short to mean anything.
        var chargesPerDay: Double?
        /// Total observed span the *drain* samples cover, in hours.
        var spanHours: Double = 0
        /// Wall-clock span of the charge-session log behind `chargesPerDay`, in
        /// hours. This is the multi-day/-week horizon the sparkline can't reach,
        /// so it — not `spanHours` — gates any long-term projection.
        var chargeLogSpanHours: Double = 0

        /// A heavy user drains fast *and* charges often — both push the advice
        /// toward earlier warnings and a stricter charge ceiling.
        var isHeavyUse: Bool {
            if let d = drainPerHour, d >= 25 { return true }
            if let c = chargesPerDay, c >= 3 { return true }
            return false
        }
    }

    /// Derive a usage profile from timestamped percentage samples (oldest first)
    /// plus a separate, long-horizon log of charge-session start times.
    ///
    /// - The drain rate uses only the most recent *monotonically non-rising*
    ///   stretch, so a charge in the middle of the window never dilutes it.
    /// - Samples more than `maxGap` apart are treated as separate sessions (the
    ///   Mac was asleep or the app was quit), because the elapsed wall time did
    ///   not correspond to real discharge.
    /// - Charge cadence comes from `chargeLog`, not the samples: the retained
    ///   sparkline history spans at most ~1 hour of observed time, far short of
    ///   the days/weeks needed for a "charges per day" figure to mean anything.
    ///   `chargeLog` is the persisted list of rising-edge timestamps (oldest
    ///   first, though it is sorted defensively here).
    static func usageProfile(from samples: [(percent: Int, time: Date)],
                             chargeLog: [Date] = [],
                             maxGap: TimeInterval = 20 * 60) -> UsageProfile {
        var profile = UsageProfile()

        if let cadence = chargeCadence(from: chargeLog) {
            profile.chargesPerDay = cadence.perDay
            profile.chargeLogSpanHours = cadence.spanHours
        }

        guard samples.count >= 2 else { return profile }

        // Observed time only: the sum of gaps we actually watched, not raw
        // first-to-last wall clock. History is persisted across launches, so a
        // Mac that was shut overnight leaves a 10-hour hole between two
        // adjacent samples — counting that hole would divide the charge cycles
        // we *did* see by a stretch of time nobody was looking.
        profile.spanHours = zip(samples, samples.dropFirst())
            .map { $0.1.time.timeIntervalSince($0.0.time) }
            .filter { $0 > 0 && $0 <= maxGap }
            .reduce(0, +) / 3600

        // --- Drain rate: walk backwards over the trailing discharge stretch.
        let endIndex = samples.count - 1
        var startIndex = endIndex
        var i = endIndex
        while i > 0 {
            let newer = samples[i]
            let older = samples[i - 1]
            let gap = newer.time.timeIntervalSince(older.time)
            // A rise means charging; a long gap means the timeline is not
            // continuous. Either way the stretch ends here.
            if newer.percent > older.percent || gap > maxGap || gap <= 0 { break }
            startIndex = i - 1
            i -= 1
        }

        let start = samples[startIndex]
        let end = samples[endIndex]
        let hours = end.time.timeIntervalSince(start.time) / 3600
        let dropped = Double(start.percent - end.percent)
        // Need a real span and a real drop, else the rate is noise.
        if hours >= 1.0 / 6.0, dropped >= 1 {
            profile.drainPerHour = dropped / hours
        }

        return profile
    }

    /// Charge frequency, learned from a persisted log of charge-session start
    /// times rather than the sparkline samples. Returns the estimated sessions
    /// per day and the log's wall-clock span in hours, or `nil` when the log is
    /// too short or too clustered to support a rate.
    ///
    /// - `minSpan` guards against a freshly-seeded log: two edges an hour apart
    ///   must not read as "24 charges a day". A rate is only offered once the
    ///   log covers at least this much wall time.
    /// - The rate uses `count − 1` over the first-to-last span: N timestamped
    ///   edges bound N−1 completed inter-charge intervals, the least-biased
    ///   estimator when the observation window's true edges are unknown. Unlike
    ///   drain, this is honest wall clock — discrete charge events carry no
    ///   "unobserved discharge" hazard to net out, so an overnight gap between
    ///   two charges is real elapsed time the cadence should count.
    static func chargeCadence(from chargeLog: [Date],
                              minSpan: TimeInterval = 12 * 3600) -> (perDay: Double, spanHours: Double)? {
        let sorted = chargeLog.sorted()
        guard sorted.count >= 2, let first = sorted.first, let last = sorted.last else { return nil }
        let span = last.timeIntervalSince(first)
        guard span >= minSpan else { return nil }
        let perDay = Double(sorted.count - 1) / (span / 86_400)
        return (perDay, span / 3600)
    }

    // MARK: - Advice

    enum Action {
        /// Plug in immediately — the battery is at or below the urgent floor.
        case chargeNow
        /// Plug in within the next while — at this drain rate it will bite soon.
        case chargeSoon
        /// Unplug: sitting at a high charge on AC ages the cell.
        case unplug
        /// Too hot to charge — let it cool before topping up.
        case coolDown
        /// Nothing to do; keep going.
        case steady
    }

    enum Urgency: Int, Comparable {
        case info = 0, notable = 1, urgent = 2
        static func < (a: Urgency, b: Urgency) -> Bool { a.rawValue < b.rawValue }
    }

    struct Advice {
        var action: Action
        var urgency: Urgency
        /// Short imperative line, e.g. "Plug in within ~25m".
        var headline: String
        /// One sentence explaining *why*, naming the input that drove it.
        var reason: String
        /// Estimated minutes until the recommendation becomes urgent, when the
        /// usage rate makes that computable.
        var minutesUntilCritical: Int?

        /// Only actionable advice is worth a notification.
        var isActionable: Bool {
            switch action {
            case .steady: return false
            default: return true
            }
        }
    }

    /// Session facts the snapshot can't carry — how long this AC session has
    /// been running, which is what turns "you're above the ceiling" into "you
    /// have been parked above the ceiling all afternoon".
    struct Context {
        /// Hours continuously on AC, or `nil` when on battery / unknown.
        var hoursOnAC: Double?
        /// Hours continuously on battery, for the same reason.
        var hoursOnBattery: Double?
    }

    /// Cycles a Mac battery is rated for before capacity is expected to taper.
    static let ratedCycles = 1000

    /// The knobs the user (or defaults) control.
    struct Policy {
        /// Percentage at/below which charging is urgent.
        var lowThreshold: Int = 10
        /// Preferred everyday ceiling — above this on AC we suggest unplugging.
        var chargeCeiling: Int = 80
        /// Preferred everyday floor — below this we start suggesting a charge.
        var chargeFloor: Int = 30
        /// °C at/above which charging should pause.
        var overheatThreshold: Int = 35
        /// How much warning to give before hitting `lowThreshold`.
        var leadTimeMinutes: Int = 30
        /// When false, the ceiling advice (unplug at 80%) is suppressed.
        var protectLongevity: Bool = true
        /// Hours parked on AC above the ceiling before the nudge escalates from
        /// a quiet note to something worth a reminder.
        var parkedHoursBeforeNudge: Double = 2
    }

    /// Where this battery sits in its rated life, 0…1+ (`nil` without a cycle
    /// count). Past ~0.8 the remaining cycles are worth actively protecting.
    static func cycleStrain(_ cycleCount: Int?) -> Double? {
        guard let c = cycleCount, c > 0 else { return nil }
        return Double(c) / Double(ratedCycles)
    }

    /// Produce the single most relevant recommendation, or `nil` when there is
    /// no battery to advise on.
    static func advise(snapshot: PowerMetrics.Snapshot,
                       usage: UsageProfile,
                       policy: Policy,
                       context: Context = Context()) -> Advice? {
        guard snapshot.hasBattery else { return nil }

        // A degraded cell has less real headroom than its percentage suggests,
        // and heavy use eats that headroom faster — so raise the floor and the
        // lead time rather than trusting the raw numbers.
        var floor = policy.chargeFloor
        var lead = policy.leadTimeMinutes
        if snapshot.healthIsDegraded { floor += 10; lead += 15 }
        if usage.isHeavyUse { lead += 15 }

        // The ceiling tightens for two independent reasons, and they stack:
        // a heavy cycler passes through the high-voltage band many times a day,
        // and a battery late in its rated life has few cycles left to spend.
        var ceiling = policy.chargeCeiling
        if usage.isHeavyUse { ceiling -= 5 }
        if let strain = cycleStrain(snapshot.cycleCount), strain >= 0.8 {
            ceiling -= 5
            // Late in life the cell also sags harder under load, so leave more
            // margin before it drops to the urgent floor.
            floor += 5
        }
        ceiling = max(ceiling, 50)
        // Re-clamp after the bumps, not just in the policy: the adjustments
        // above push the floor up by as much as 15 while pulling the ceiling
        // down by 10, so a degraded, high-cycle battery could end with the
        // floor above the ceiling — "charge now" on battery, "unplug" on AC,
        // and no state that satisfies either.
        floor = min(floor, ceiling - 10)

        let pct = snapshot.percentage
        let hot = (snapshot.temperatureC ?? 0) >= Double(policy.overheatThreshold)
        let onAC = snapshot.powerSource == .ac
        let charging = snapshot.state == .charging

        // --- Heat beats everything except an actually-empty battery.
        if hot, onAC, charging, let p = pct, p > policy.lowThreshold {
            return Advice(
                action: .coolDown,
                urgency: .notable,
                headline: "Pause charging until it cools",
                reason: String(format: "Battery is %.1f°C while charging — heat plus a high charge is what ages the cell fastest.",
                               snapshot.temperatureC ?? 0),
                minutesUntilCritical: nil
            )
        }

        if !onAC || snapshot.state == .discharging {
            return dischargingAdvice(snapshot: snapshot, usage: usage,
                                     policy: policy, floor: floor, lead: lead)
        }

        return pluggedAdvice(snapshot: snapshot, usage: usage,
                             policy: policy, ceiling: ceiling, context: context)
    }

    // MARK: - Branches

    private static func dischargingAdvice(snapshot: PowerMetrics.Snapshot,
                                          usage: UsageProfile,
                                          policy: Policy,
                                          floor: Int,
                                          lead: Int) -> Advice {
        let pct = snapshot.percentage ?? 100
        let minutesLeft = minutesToReach(policy.lowThreshold,
                                         from: pct,
                                         snapshot: snapshot,
                                         usage: usage)

        if pct <= policy.lowThreshold {
            return Advice(
                action: .chargeNow,
                urgency: .urgent,
                headline: "Plug in now — \(pct)%",
                reason: snapshot.timeToEmptyMinutes.map { "About \(formatMins($0)) of runtime left at the current draw." }
                    ?? "At or below your \(policy.lowThreshold)% floor.",
                minutesUntilCritical: 0
            )
        }

        if let m = minutesLeft, m <= lead {
            return Advice(
                action: .chargeSoon,
                urgency: .notable,
                headline: "Plug in within ~\(formatMins(m))",
                reason: reasonForRate(usage: usage, snapshot: snapshot,
                                      target: policy.lowThreshold),
                minutesUntilCritical: m
            )
        }

        if pct <= floor {
            let extra = snapshot.healthIsDegraded
                ? " Battery health is degraded, so charge earlier than the percentage suggests."
                : ""
            return Advice(
                action: .chargeSoon,
                urgency: .notable,
                headline: "Charge soon — \(pct)%",
                reason: "Below your \(floor)% comfort floor.\(extra)",
                minutesUntilCritical: minutesLeft
            )
        }

        return Advice(
            action: .steady,
            urgency: .info,
            headline: "No need to charge",
            reason: reasonForRate(usage: usage, snapshot: snapshot,
                                  target: policy.lowThreshold),
            minutesUntilCritical: minutesLeft
        )
    }

    private static func pluggedAdvice(snapshot: PowerMetrics.Snapshot,
                                      usage: UsageProfile,
                                      policy: Policy,
                                      ceiling: Int,
                                      context: Context) -> Advice {
        let pct = snapshot.percentage ?? 0
        let full = snapshot.state == .charged || pct >= 100

        if policy.protectLongevity, pct >= ceiling {
            // Wear above the ceiling is a *dose*: it accrues per hour parked
            // there, so a long AC session escalates the same advice. Below the
            // ceiling, staying plugged in is harmless — duration is only ever
            // held against time spent in the high-voltage band.
            let parked = context.hoursOnAC ?? 0
            let isParked = parked >= policy.parkedHoursBeforeNudge

            let headline: String
            if isParked {
                headline = "On AC at \(pct)% for \(formatHours(parked)) — unplug"
            } else if full {
                headline = "Fully charged — unplug"
            } else {
                headline = "Enough charge — you can unplug"
            }

            // The reason names whichever of the user's own numbers actually
            // drove the advice, so it reads as evidence rather than a platitude.
            let why: String
            if let cycles = snapshot.cycleCount, let strain = cycleStrain(cycles), strain >= 0.8 {
                why = "\(cycles) of ~\(ratedCycles) rated cycles used"
                    + (isParked ? ", and \(formatHours(parked)) parked above \(ceiling)% is exactly what spends the rest."
                               : " — time above \(ceiling)% is what spends the rest.")
            } else if isParked {
                why = "\(formatHours(parked)) at \(pct)% on AC. Wear in the high-voltage band accrues per hour, not per charge."
            } else if full {
                why = "Holding at 100% on AC keeps the cell at peak voltage, which wears it faster than cycling in the middle of its range."
            } else if usage.isHeavyUse {
                let rate = usage.chargesPerDay.map { String(format: "You charge about %.1f×/day", $0) } ?? "You charge often"
                why = "\(rate), so every trip above \(ceiling)% adds avoidable wear."
            } else {
                why = "Above \(ceiling)% the charge sits in the high-voltage band, where wear per hour is highest."
            }

            return Advice(
                action: .unplug,
                urgency: (full || isParked) ? .notable : .info,
                headline: headline,
                reason: why,
                minutesUntilCritical: nil
            )
        }

        let target = policy.protectLongevity ? ceiling : 100
        let toTarget = minutesToCharge(to: target, from: pct, snapshot: snapshot)
        return Advice(
            action: .steady,
            urgency: .info,
            headline: toTarget.map { "Charging — ~\(formatMins($0)) to \(target)%" }
                ?? "Charging",
            reason: "Keeping day-to-day charge between \(policy.chargeFloor)–\(ceiling)% is the single biggest lever on battery lifespan.",
            minutesUntilCritical: nil
        )
    }

    // MARK: - Estimates

    /// Minutes until the charge falls to `target`, preferring the OS estimate
    /// (which already accounts for the live draw) and falling back to the
    /// learned drain rate.
    static func minutesToReach(_ target: Int,
                               from pct: Int,
                               snapshot: PowerMetrics.Snapshot,
                               usage: UsageProfile) -> Int? {
        guard pct > target else { return 0 }
        if let toEmpty = snapshot.timeToEmptyMinutes, pct > 0 {
            // The OS reports minutes to 0%; scale to the target linearly.
            let fraction = Double(pct - target) / Double(pct)
            return max(0, Int((Double(toEmpty) * fraction).rounded()))
        }
        if let rate = usage.drainPerHour, rate > 0.5 {
            return max(0, Int((Double(pct - target) / rate * 60).rounded()))
        }
        return nil
    }

    private static func minutesToCharge(to target: Int,
                                        from pct: Int,
                                        snapshot: PowerMetrics.Snapshot) -> Int? {
        guard pct < target, let toFull = snapshot.timeToFullMinutes, pct < 100 else { return nil }
        let fraction = Double(target - pct) / Double(100 - pct)
        return max(0, Int((Double(toFull) * fraction).rounded()))
    }

    private static func reasonForRate(usage: UsageProfile,
                                      snapshot: PowerMetrics.Snapshot,
                                      target: Int) -> String {
        if let rate = usage.drainPerHour, rate > 0.5 {
            return String(format: "Draining about %.0f%%/hour at your recent usage.", rate)
        }
        if let toEmpty = snapshot.timeToEmptyMinutes {
            return "About \(formatMins(toEmpty)) of runtime left at the current draw."
        }
        return "Above your \(target)% floor."
    }

    private static func formatHours(_ hours: Double) -> String {
        if hours < 1 { return "\(Int((hours * 60).rounded()))m" }
        let h = Int(hours)
        let m = Int(((hours - Double(h)) * 60).rounded())
        return m >= 5 ? "\(h)h \(m)m" : "\(h)h"
    }

    private static func formatMins(_ minutes: Int) -> String {
        guard minutes > 0 else { return "0m" }
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }
}
