// Plain `swiftc` harness for the pure PowerAdvisor logic — no Xcode, no IOKit
// calls at runtime (PowerMetrics is compiled for its types only; this harness
// is macOS-only because PowerMetrics imports IOKit).
//
// Run from the repo root:
//
//   swiftc -o /private/tmp/gk-advisor-harness \
//     Glancekit/Plugins/Power/PowerAdvisor.swift \
//     Glancekit/Plugins/Power/PowerMetrics.swift \
//     scripts/power_advisor_harness.swift && /private/tmp/gk-advisor-harness
//
// Exits non-zero on the first failed expectation.

import Foundation

var failures = 0
func check(_ cond: Bool, _ label: String) {
    if cond { print("ok   — \(label)") }
    else { print("FAIL — \(label)"); failures += 1 }
}
func approx(_ a: Double?, _ b: Double, _ tol: Double = 0.001, _ label: String) {
    guard let a else { check(false, "\(label) (was nil)"); return }
    check(abs(a - b) <= tol, "\(label) (\(a) ≈ \(b))")
}

let base = Date(timeIntervalSince1970: 1_000_000)
let minute: TimeInterval = 60
let hour: TimeInterval = 3600
let day: TimeInterval = 86_400
func t(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

// MARK: chargeCadence

check(PowerAdvisor.chargeCadence(from: []) == nil, "empty log → nil")
check(PowerAdvisor.chargeCadence(from: [t(0)]) == nil, "single edge → nil")

// Two edges only an hour apart: below the 12h minimum span → nil, never "24/day".
check(PowerAdvisor.chargeCadence(from: [t(0), t(hour)]) == nil,
      "two edges within minSpan → nil")

// 8 edges, one per day, spanning exactly 7 days → (8-1)/7 = 1.0/day.
let weekLog = (0...7).map { t(Double($0) * day) }
approx(PowerAdvisor.chargeCadence(from: weekLog)?.perDay, 1.0, 0.001, "weekly log → 1.0/day")
approx(PowerAdvisor.chargeCadence(from: weekLog)?.spanHours, 168, 0.001, "weekly log span → 168h")

// 6 edges spanning exactly 2 days → (6-1)/2 = 2.5/day.
let moderateLog = [t(0), t(8 * hour), t(16 * hour), t(day), t(day + 12 * hour), t(2 * day)]
approx(PowerAdvisor.chargeCadence(from: moderateLog)?.perDay, 2.5, 0.001, "moderate log → 2.5/day")

// 9 edges spanning exactly 2 days → (9-1)/2 = 4.0/day.
let heavyLog = [t(0), t(6 * hour), t(12 * hour), t(18 * hour),
                t(day), t(day + 6 * hour), t(day + 12 * hour), t(day + 18 * hour), t(2 * day)]
approx(PowerAdvisor.chargeCadence(from: heavyLog)?.perDay, 4.0, 0.001, "heavy log → 4.0/day")

// Unsorted input must be sorted defensively: same 2.5/day as moderateLog.
approx(PowerAdvisor.chargeCadence(from: moderateLog.reversed())?.perDay, 2.5, 0.001,
       "reversed log → sorted, 2.5/day")

// MARK: usageProfile wiring

// Drain comes from the samples; cadence comes from the log — independently.
// Samples sit within the 20-min maxGap so they form one discharge stretch:
// 2% over 24 min → 5%/h.
let samples: [(percent: Int, time: Date)] = [(85, t(0)), (84, t(12 * minute)), (83, t(24 * minute))]
let profile = PowerAdvisor.usageProfile(from: samples, chargeLog: moderateLog)
approx(profile.drainPerHour, 5.0, 0.01, "drainPerHour from samples (5%/h)")
approx(profile.chargesPerDay, 2.5, 0.001, "chargesPerDay from log (2.5/day)")
approx(profile.chargeLogSpanHours, 48, 0.001, "chargeLogSpanHours reflects log horizon (48h)")

// The charge-cadence arm of isHeavyUse is now reachable: light drain, heavy charging.
let frequent = PowerAdvisor.usageProfile(
    from: [(70, t(0)), (69, t(10 * minute))],   // 6%/h — not heavy by drain
    chargeLog: heavyLog)                 // 4.0/day — heavy by cadence
check(frequent.isHeavyUse, "isHeavyUse charge-cadence arm fires (4.0/day ≥ 3)")
check((frequent.drainPerHour ?? 99) < 25, "…and not via the drain arm")

// Just under the cadence threshold must NOT read as heavy on its own.
check(!PowerAdvisor.usageProfile(from: [(70, t(0)), (69, t(10 * minute))],
                                 chargeLog: moderateLog).isHeavyUse,
      "2.5/day alone is not heavy use")

// No log → no cadence; the rest of the profile is unaffected.
let noLog = PowerAdvisor.usageProfile(from: samples)
check(noLog.chargesPerDay == nil, "no log → chargesPerDay nil")
check(noLog.chargeLogSpanHours == 0, "no log → chargeLogSpanHours zero")
approx(noLog.drainPerHour, 5.0, 0.01, "no log → drain still computed")

// Regression: an hour of dense samples must never fabricate cadence on its own
// (the defect this change fixes — the old sample rising-edge counter is gone).
let denseHour: [(percent: Int, time: Date)] = (0..<120).map {
    (80 + ($0 % 5), t(Double($0) * 30))   // 120 samples 30s apart ≈ 1h, wiggling
}
check(PowerAdvisor.usageProfile(from: denseHour).chargesPerDay == nil,
      "1h of samples alone → no chargesPerDay (regression guard)")

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
