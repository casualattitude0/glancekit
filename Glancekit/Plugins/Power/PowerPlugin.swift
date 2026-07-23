import SwiftUI
import Observation

/// A rich battery/power glance that goes deeper than the basic battery % in the
/// Mac Health glance: cycle count, battery health %, temperature, adapter
/// wattage, condition, and a rolling charge-history sparkline.
///
/// All readings come from IOKit (`PowerMetrics`) — no network, no secrets.
@MainActor
@Observable
final class PowerPlugin: GlancePlugin {
    nonisolated var id: String { "power" }
    nonisolated var title: String { "Power" }
    nonisolated var iconSystemName: String { "battery.100.bolt" }
    var refreshInterval: TimeInterval { 30 }

    /// A recommended popover size — the details grid + sparkline want room.
    var preferredToolWindowSize: CGSize? { CGSize(width: 320, height: 380) }

    // MARK: State

    private(set) var snapshot = PowerMetrics.Snapshot()

    /// Rolling charge history: percentage samples with timestamps, capped at
    /// `maxHistory`, persisted so the sparkline survives relaunches.
    private(set) var history: [HistorySample] = []
    private let maxHistory = 120

    /// A separate, long-horizon log of charge-session start times (one timestamp
    /// per rising edge into a charge). Capped small but kept for weeks, so charge
    /// cadence has a horizon the ~1-hour sparkline can never reach. Persisted on
    /// its own key rather than by inflating `maxHistory`, which would bloat the
    /// sparkline payload and slow its rendering for a figure the sparkline never
    /// shows.
    private(set) var chargeLog: [Date] = []
    private let maxChargeLog = 60

    /// The instant the Mac was last unplugged (moved onto battery), persisted so
    /// "time on battery" survives a relaunch while still unplugged. `nil` when
    /// on AC or unknown.
    private(set) var unplugDate: Date?

    /// The instant the Mac was last plugged in, persisted for the same reason —
    /// "parked on AC at 92% for 6h" has to survive a relaunch or the advice
    /// resets itself every time the app restarts.
    private(set) var plugDate: Date?

    /// Whether the current charge session already fired the full-charge alert,
    /// and whether an overheat alert is currently latched (hysteresis). Both are
    /// in-memory only — they should re-arm on relaunch.
    private var firedFullChargeAlert = false
    private var overheatLatched = false

    /// Consecutive non-actionable readings seen since the last actionable one.
    /// The reminder re-arms only once this reaches `readingsToRearm`, so a
    /// single jittery `.steady` between two real warnings doesn't reset it.
    private var steadyReadings = 0

    /// ~90s at the 30s refresh interval.
    private static let readingsToRearm = 3

    /// When the last charge reminder fired — the cooldown's anchor.
    private var lastReminderDate: Date?

    /// Reminders stay quiet until this instant — set by the Smart Panel card's
    /// "Snooze" action. Persisted so quitting the app isn't a way to un-snooze.
    private(set) var reminderSnoozeUntil: Date?
    private let snoozeKey = "glancekit.power.reminderSnoozeUntil"

    // MARK: Persisted preferences

    var showHealth: Bool {
        didSet { UserDefaults.standard.set(showHealth, forKey: "glancekit.power.showHealth") }
    }
    var showCycles: Bool {
        didSet { UserDefaults.standard.set(showCycles, forKey: "glancekit.power.showCycles") }
    }
    var showTemperature: Bool {
        didSet { UserDefaults.standard.set(showTemperature, forKey: "glancekit.power.showTemperature") }
    }
    var showAdapter: Bool {
        didSet { UserDefaults.standard.set(showAdapter, forKey: "glancekit.power.showAdapter") }
    }
    var showCondition: Bool {
        didSet { UserDefaults.standard.set(showCondition, forKey: "glancekit.power.showCondition") }
    }
    var showPower: Bool {
        didSet { UserDefaults.standard.set(showPower, forKey: "glancekit.power.showPower") }
    }
    var showVoltage: Bool {
        didSet { UserDefaults.standard.set(showVoltage, forKey: "glancekit.power.showVoltage") }
    }
    var showCapacity: Bool {
        didSet { UserDefaults.standard.set(showCapacity, forKey: "glancekit.power.showCapacity") }
    }
    var showTimeOnBattery: Bool {
        didSet { UserDefaults.standard.set(showTimeOnBattery, forKey: "glancekit.power.showTimeOnBattery") }
    }
    /// A one-line "health at a glance" summary shown under the header.
    var showSummary: Bool {
        didSet { UserDefaults.standard.set(showSummary, forKey: "glancekit.power.showSummary") }
    }
    /// A single actionable suggestion to improve battery longevity/usage.
    var showTip: Bool {
        didSet { UserDefaults.standard.set(showTip, forKey: "glancekit.power.showTip") }
    }
    /// Percentage at/below which a discharging battery earns an urgent signal.
    var lowThreshold: Int {
        didSet { UserDefaults.standard.set(lowThreshold, forKey: "glancekit.power.lowThreshold") }
    }

    /// How many of the most-recent samples the sparkline draws (30 / 60 / 120).
    var historyWindow: Int {
        didSet { UserDefaults.standard.set(historyWindow, forKey: "glancekit.power.historyWindow") }
    }

    /// Show the charge advisor card (what to do right now) in the popover.
    var showAdvice: Bool {
        didSet { UserDefaults.standard.set(showAdvice, forKey: "glancekit.power.showAdvice") }
    }
    /// Remind me with a notification when the advice becomes actionable.
    var remindCharge: Bool {
        didSet { UserDefaults.standard.set(remindCharge, forKey: "glancekit.power.remindCharge") }
    }
    /// Minimum minutes between two charge reminders for the same advice.
    var reminderCooldownMinutes: Int {
        didSet { UserDefaults.standard.set(reminderCooldownMinutes, forKey: "glancekit.power.reminderCooldown") }
    }
    /// Everyday charge ceiling — above this on AC the advisor says "unplug".
    var chargeCeiling: Int {
        didSet { UserDefaults.standard.set(chargeCeiling, forKey: "glancekit.power.chargeCeiling") }
    }
    /// Everyday comfort floor — below this the advisor starts nudging to charge.
    var chargeFloor: Int {
        didSet { UserDefaults.standard.set(chargeFloor, forKey: "glancekit.power.chargeFloor") }
    }
    /// How much warning to give before the battery reaches `lowThreshold`.
    var reminderLeadMinutes: Int {
        didSet { UserDefaults.standard.set(reminderLeadMinutes, forKey: "glancekit.power.reminderLead") }
    }
    /// When off, the advisor never suggests unplugging at the ceiling.
    var protectLongevity: Bool {
        didSet { UserDefaults.standard.set(protectLongevity, forKey: "glancekit.power.protectLongevity") }
    }

    /// Alert once when the battery reaches a full charge while plugged in.
    var alertFullCharge: Bool {
        didSet { UserDefaults.standard.set(alertFullCharge, forKey: "glancekit.power.alertFullCharge") }
    }
    /// Alert when battery temperature crosses `overheatThreshold` °C.
    var alertOverheat: Bool {
        didSet { UserDefaults.standard.set(alertOverheat, forKey: "glancekit.power.alertOverheat") }
    }
    var overheatThreshold: Int {
        didSet { UserDefaults.standard.set(overheatThreshold, forKey: "glancekit.power.overheatThreshold") }
    }

    struct HistorySample: Codable {
        let percent: Int
        let time: Date
    }

    private let historyKey = "glancekit.power.history"
    private let chargeLogKey = "glancekit.power.chargeLog"
    private let unplugDateKey = "glancekit.power.unplugDate"
    private let plugDateKey = "glancekit.power.plugDate"

    init() {
        let d = UserDefaults.standard
        showHealth = d.object(forKey: "glancekit.power.showHealth") as? Bool ?? true
        showCycles = d.object(forKey: "glancekit.power.showCycles") as? Bool ?? true
        showTemperature = d.object(forKey: "glancekit.power.showTemperature") as? Bool ?? true
        showAdapter = d.object(forKey: "glancekit.power.showAdapter") as? Bool ?? true
        showCondition = d.object(forKey: "glancekit.power.showCondition") as? Bool ?? true
        showPower = d.object(forKey: "glancekit.power.showPower") as? Bool ?? true
        showVoltage = d.object(forKey: "glancekit.power.showVoltage") as? Bool ?? false
        showCapacity = d.object(forKey: "glancekit.power.showCapacity") as? Bool ?? false
        showTimeOnBattery = d.object(forKey: "glancekit.power.showTimeOnBattery") as? Bool ?? true
        showSummary = d.object(forKey: "glancekit.power.showSummary") as? Bool ?? true
        showTip = d.object(forKey: "glancekit.power.showTip") as? Bool ?? true
        lowThreshold = d.object(forKey: "glancekit.power.lowThreshold") as? Int ?? 10

        let savedWindow = d.object(forKey: "glancekit.power.historyWindow") as? Int ?? 120
        historyWindow = [30, 60, 120].contains(savedWindow) ? savedWindow : 120

        showAdvice = d.object(forKey: "glancekit.power.showAdvice") as? Bool ?? true
        remindCharge = d.object(forKey: "glancekit.power.remindCharge") as? Bool ?? false
        reminderCooldownMinutes = d.object(forKey: "glancekit.power.reminderCooldown") as? Int ?? 60
        chargeCeiling = d.object(forKey: "glancekit.power.chargeCeiling") as? Int ?? 80
        chargeFloor = d.object(forKey: "glancekit.power.chargeFloor") as? Int ?? 30
        reminderLeadMinutes = d.object(forKey: "glancekit.power.reminderLead") as? Int ?? 30
        protectLongevity = d.object(forKey: "glancekit.power.protectLongevity") as? Bool ?? true

        alertFullCharge = d.object(forKey: "glancekit.power.alertFullCharge") as? Bool ?? false
        alertOverheat = d.object(forKey: "glancekit.power.alertOverheat") as? Bool ?? false
        overheatThreshold = d.object(forKey: "glancekit.power.overheatThreshold") as? Int ?? 35

        if let data = d.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([HistorySample].self, from: data) {
            history = decoded
        }
        if let data = d.data(forKey: chargeLogKey),
           let decoded = try? JSONDecoder().decode([Date].self, from: data) {
            chargeLog = decoded
        }
        unplugDate = d.object(forKey: unplugDateKey) as? Date
        plugDate = d.object(forKey: plugDateKey) as? Date
        reminderSnoozeUntil = d.object(forKey: snoozeKey) as? Date
    }

    /// Mute charge reminders for a while (Smart Panel "Snooze" button). The
    /// advice card itself keeps showing — this only silences the notification.
    func snoozeReminders(minutes: Int = 60) {
        let until = Date().addingTimeInterval(Double(minutes) * 60)
        reminderSnoozeUntil = until
        UserDefaults.standard.set(until, forKey: snoozeKey)
    }

    /// Un-mute reminders immediately (the popover's "Resume").
    func endSnooze() { clearSnooze() }

    private func clearSnooze() {
        guard reminderSnoozeUntil != nil else { return }
        reminderSnoozeUntil = nil
        UserDefaults.standard.removeObject(forKey: snoozeKey)
    }

    // MARK: GlancePlugin

    func refresh() async {
        snapshot = PowerMetrics.read()
        if let pct = snapshot.percentage {
            history.append(HistorySample(percent: pct, time: Date()))
            if history.count > maxHistory {
                history.removeFirst(history.count - maxHistory)
            }
            if let data = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(data, forKey: historyKey)
            }
        }
        updateUnplugTracking()
        recordChargeSession()
        usage = PowerAdvisor.usageProfile(from: history.map { ($0.percent, $0.time) },
                                          chargeLog: chargeLog)
        evaluateAlerts()
        evaluateChargeReminder()
    }

    /// Empty the charge-history buffer and persisted copy. The long-horizon
    /// charge-cadence log is a separate record, but "clear history" is the
    /// user's reset-my-usage gesture, so it goes too.
    func clearHistory() {
        history.removeAll()
        chargeLog.removeAll()
        UserDefaults.standard.removeObject(forKey: historyKey)
        UserDefaults.standard.removeObject(forKey: chargeLogKey)
    }

    /// Append a rising-edge timestamp when a new charge session begins, feeding
    /// the long-horizon cadence log that `chargesPerDay` is derived from.
    ///
    /// One event per AC session: the session's plug-in instant (`plugDate`,
    /// itself persisted) is the boundary. If the newest logged edge already sits
    /// at or after it, this charge is counted — so a mid-charge relaunch (which
    /// re-observes the charging state from scratch) and a brief charging flicker
    /// within one session both collapse to a single event, never a duplicate.
    /// Must run after `updateUnplugTracking()` so `plugDate` reflects this tick.
    private func recordChargeSession() {
        guard snapshot.hasBattery, snapshot.state == .charging else { return }
        guard let session = plugDate else { return }
        if let last = chargeLog.last, last >= session { return }

        chargeLog.append(Date())
        if chargeLog.count > maxChargeLog {
            chargeLog.removeFirst(chargeLog.count - maxChargeLog)
        }
        if let data = try? JSONEncoder().encode(chargeLog) {
            UserDefaults.standard.set(data, forKey: chargeLogKey)
        }
    }

    /// Elapsed time since the Mac was last unplugged, while still on battery.
    var timeOnBattery: TimeInterval? {
        guard snapshot.hasBattery,
              snapshot.powerSource == .battery,
              let start = unplugDate else { return nil }
        return max(0, Date().timeIntervalSince(start))
    }

    /// What the recent history says about how hard this Mac gets used. Recomputed
    /// once per refresh (the advice itself is derived on demand, so changing a
    /// setting updates the card immediately).
    private(set) var usage = PowerAdvisor.UsageProfile()

    /// The live charge/unplug recommendation, or `nil` on a desktop Mac.
    var advice: PowerAdvisor.Advice? {
        PowerAdvisor.advise(snapshot: snapshot, usage: usage, policy: advisorPolicy,
                            context: PowerAdvisor.Context(
                                hoursOnAC: timeOnAC.map { $0 / 3600 },
                                hoursOnBattery: timeOnBattery.map { $0 / 3600 }
                            ))
    }

    /// How fast this Mac is spending its rated cycle life, in the user's own
    /// terms: cycles used, the charge cadence behind them, and — when the
    /// history is long enough to mean anything — how long the rest will last.
    var cyclePace: String? {
        guard let cycles = snapshot.cycleCount, cycles > 0 else { return nil }
        var parts = ["\(cycles) of ~\(PowerAdvisor.ratedCycles) cycles"]
        if let perDay = usage.chargesPerDay, perDay > 0.1 {
            parts.append(String(format: "~%.1f charges/day", perDay))
            let remaining = Double(PowerAdvisor.ratedCycles - cycles)
            // Gate on the charge-log horizon, not the ~1-hour sparkline span:
            // projecting years of remaining life demands at least a couple of
            // days of observed charging cadence to be anything but noise.
            if remaining > 0, usage.chargeLogSpanHours >= 48 {
                let months = remaining / perDay / 30.0
                if months < 120 {
                    parts.append(months >= 12
                                 ? String(format: "~%.0f yr at this pace", months / 12)
                                 : String(format: "~%.0f mo at this pace", months))
                }
            }
        }
        return parts.joined(separator: " · ")
    }

    private var advisorPolicy: PowerAdvisor.Policy {
        PowerAdvisor.Policy(
            lowThreshold: lowThreshold,
            chargeCeiling: chargeCeiling,
            // Kept a clear band below the ceiling. Without this an inverted
            // pair (floor 60, ceiling 50) makes the advisor demand a charge on
            // battery and an unplug on AC — a flip-flop with no resting state.
            // Clamped here as well as at the steppers, so a pair already
            // persisted by an older build is corrected on read.
            chargeFloor: min(max(chargeFloor, lowThreshold + 5), chargeCeiling - 10),
            overheatThreshold: overheatThreshold,
            leadTimeMinutes: reminderLeadMinutes,
            protectLongevity: protectLongevity
        )
    }

    /// A single, actionable suggestion for improving battery longevity or
    /// stretching the current charge, chosen from the live snapshot. Ordered
    /// most-pressing first so the popover always shows the one thing most worth
    /// doing right now. `nil` when nothing useful applies (or no battery).
    var batteryTip: String? {
        guard snapshot.hasBattery else { return nil }

        // Hardware concerns first — these outweigh any charging-habit advice.
        if snapshot.healthIsDegraded {
            return "Battery health is low. An Apple service check can restore full capacity."
        }
        if let t = snapshot.temperatureC, t >= Double(overheatThreshold) {
            return "Battery is running warm. Move it off direct heat and quit heavy apps — sustained heat ages the cell."
        }

        // Sitting plugged in at 100% keeps the cell at peak voltage, which wears
        // it faster than cycling in the middle of its range.
        if snapshot.powerSource == .ac,
           snapshot.state == .charged || snapshot.percentage == 100 {
            return "Fully charged on AC. Unplug, or turn on Optimized Battery Charging, to reduce long-term wear."
        }

        // Draining hard on battery: trim the load to stretch the remaining charge.
        if snapshot.state == .discharging, let w = snapshot.powerWatts, w <= -20 {
            return "High power draw. Lower screen brightness and quit background apps to extend runtime."
        }

        // Low, but not yet at the urgent threshold — nudge before it bites.
        if snapshot.state == .discharging, let pct = snapshot.percentage,
           pct > lowThreshold, pct <= lowThreshold + 10 {
            return "Charge is getting low. Plug in soon to stay above \(lowThreshold)%."
        }

        // An aging cell: not urgent, but worth planning for.
        if let cycles = snapshot.cycleCount, cycles >= 800 {
            return "\(cycles) charge cycles logged (rated ~1000). Capacity will keep tapering — plan for an eventual replacement."
        }

        // Healthy and topped up on AC: a general longevity nudge.
        if snapshot.powerSource == .ac, let pct = snapshot.percentage, pct >= 80 {
            return "Keeping day-to-day charge between 20–80% slows battery wear over time."
        }

        return nil
    }

    /// Track the unplug instant: set it the moment we move onto battery, clear
    /// it whenever we're on AC (or have no battery).
    private func updateUnplugTracking() {
        let onBattery = snapshot.hasBattery && snapshot.powerSource == .battery
        if onBattery {
            if unplugDate == nil {
                unplugDate = Date()
                UserDefaults.standard.set(unplugDate, forKey: unplugDateKey)
            }
            if plugDate != nil {
                plugDate = nil
                UserDefaults.standard.removeObject(forKey: plugDateKey)
            }
        } else {
            if unplugDate != nil {
                unplugDate = nil
                UserDefaults.standard.removeObject(forKey: unplugDateKey)
            }
            // Only an actual AC session starts the clock — a desktop with no
            // battery has nothing to be "parked" about.
            if snapshot.hasBattery, snapshot.powerSource == .ac, plugDate == nil {
                plugDate = Date()
                UserDefaults.standard.set(plugDate, forKey: plugDateKey)
            }
        }
    }

    /// Elapsed time on AC in this session, mirroring `timeOnBattery`.
    var timeOnAC: TimeInterval? {
        guard snapshot.hasBattery,
              snapshot.powerSource == .ac,
              let start = plugDate else { return nil }
        return max(0, Date().timeIntervalSince(start))
    }

    /// Best-effort, self-managed alerts. Each condition fires at most once per
    /// crossing so we never spam the user.
    private func evaluateAlerts() {
        guard snapshot.hasBattery else { return }

        // Full-charge reminder: once per charge session, re-armed on unplug.
        let isFull = snapshot.state == .charged || snapshot.percentage == 100
        let plugged = snapshot.powerSource == .ac
        if alertFullCharge, isFull, plugged {
            if !firedFullChargeAlert {
                firedFullChargeAlert = true
                NotificationService.post(
                    title: "Battery fully charged",
                    body: "Your Mac has reached 100%. You can unplug it.",
                    tint: .green,
                    identifier: "full-charge-\(UUID().uuidString.prefix(8))",
                    source: "power"
                )
            }
        } else if !plugged || snapshot.state == .discharging {
            firedFullChargeAlert = false
        }

        // Overheat note with hysteresis: fire when crossing the threshold, re-arm
        // only after the temperature drops a couple of degrees below it.
        if alertOverheat, let t = snapshot.temperatureC {
            if t >= Double(overheatThreshold) {
                if !overheatLatched {
                    overheatLatched = true
                    NotificationService.post(
                        title: "Battery running warm",
                        body: String(format: "Battery is %.1f°C (threshold %d°C).",
                                     t, overheatThreshold),
                        tint: .orange,
                        identifier: "overheat-\(UUID().uuidString.prefix(8))",
                        source: "power"
                    )
                }
            } else if t < Double(overheatThreshold) - 2 {
                overheatLatched = false
            }
        }
    }

    /// Remind the user to charge (or unplug) when the advisor turns actionable.
    ///
    /// Two guards keep this from nagging: nothing fires twice inside the
    /// cooldown, and the reminder only re-arms once the advice has been quiet
    /// for a few readings — so a plug-in or an unplug clears the state that
    /// produced the last reminder, but a flicker doesn't.
    ///
    /// Both guards are deliberately blunt, because the input is noisy.
    /// `refresh()` runs every 30s and `minutesToReach` rides on IOKit's
    /// `timeToEmptyMinutes`, which jitters by minutes between samples: a
    /// battery sitting near the lead time crosses back and forth. Keying the
    /// cooldown on *which* advice fired let every one of those crossings
    /// through, and re-arming on a single `.steady` reading let a flicker
    /// cancel a snooze the user had just set.
    private func evaluateChargeReminder() {
        guard remindCharge, snapshot.hasBattery, let advice else { return }

        guard advice.isActionable else {
            steadyReadings += 1
            // ~90s of quiet before believing it. Anything less is jitter.
            if steadyReadings >= Self.readingsToRearm {
                lastReminderDate = nil
                // Whatever the user snoozed has resolved itself — un-mute.
                clearSnooze()
            }
            return
        }
        steadyReadings = 0

        // An explicit snooze outranks the cooldown, except for a truly urgent
        // "plug in now": an empty battery is worth breaking the silence for.
        if let until = reminderSnoozeUntil, Date() < until, advice.urgency != .urgent {
            return
        }

        // Keyed on the last notification, not on what it was about: a battery
        // near the lead time alternates between "charge soon" and "unplug", and
        // matching on the action would let each alternation past the cooldown.
        if let last = lastReminderDate,
           Date().timeIntervalSince(last) < Double(reminderCooldownMinutes) * 60 {
            return
        }

        lastReminderDate = Date()
        // Fires repeatedly on the cooldown, so the identifier has to vary: an id
        // still sitting in Notification Center would be rewritten in place and
        // draw no banner, silencing exactly the reminders that recur.
        NotificationService.post(
            title: advice.headline,
            body: advice.reason,
            tint: advice.urgency == .urgent ? .red : .orange,
            identifier: "charge-\(UUID().uuidString.prefix(8))",
            source: "power")
    }

    /// The Smart Panel card is the advisor's verdict, not a raw battery readout:
    /// the same charge/unplug/cool-down recommendation the popover shows, ranked
    /// by how soon it needs acting on, with the charge level as a gauge and a
    /// one-click snooze for its reminder.
    ///
    /// Battery *health* — the thing the basic battery readout never tells you —
    /// still gets its own elevated card, but only when the advisor has nothing
    /// time-sensitive to say, so an urgent "plug in" is never buried under it.
    func currentSignal() -> GlanceSignal? {
        guard snapshot.hasBattery, let advice else { return nil }

        let pct = snapshot.percentage
        let gauge: GlanceSignal.Accessory = pct.map { .gauge(Double($0) / 100) } ?? .none

        switch advice.action {
        case .chargeNow:
            return GlanceSignal(
                priority: .urgent,
                score: Double(100 - (pct ?? 0)),
                headline: cardHeadline(advice),
                detail: advice.reason,
                systemImage: "battery.25",
                tint: .red,
                accessory: gauge
                // No snooze here: an urgent reminder ignores the snooze anyway,
                // so offering the button would be a lie.
            )

        case .chargeSoon:
            // Nearer deadline ranks higher, so two "charge soon" cards from
            // different sessions still order sensibly.
            let minutes = advice.minutesUntilCritical ?? 120
            return GlanceSignal(
                priority: .elevated,
                score: Double(max(0, 100 - minutes)),
                headline: cardHeadline(advice),
                detail: advice.reason,
                systemImage: "powerplug.fill",
                tint: .orange,
                accessory: gauge,
                quickAction: snoozeAction()
            )

        case .coolDown:
            return GlanceSignal(
                priority: .elevated,
                score: snapshot.temperatureC ?? 40,
                headline: advice.headline,
                detail: advice.reason,
                systemImage: "thermometer.high",
                tint: .orange,
                accessory: gauge,
                quickAction: snoozeAction()
            )

        case .unplug:
            return GlanceSignal(
                priority: advice.urgency == .notable ? .elevated : .normal,
                score: Double(pct ?? 100),
                headline: cardHeadline(advice),
                detail: advice.reason,
                systemImage: "powerplug",
                tint: .green,
                accessory: gauge,
                quickAction: snoozeAction()
            )

        case .steady:
            // Nothing to do about the charge — fall back to the standing health
            // story, or a quiet ambient reading so the panel still shows power.
            if snapshot.healthIsDegraded {
                let healthText = snapshot.healthPercent.map { "\($0)%" } ?? "low"
                return GlanceSignal(
                    priority: .elevated,
                    score: Double(100 - (snapshot.healthPercent ?? 0)),
                    headline: "Battery health \(healthText)",
                    detail: snapshot.condition ?? "Service recommended",
                    systemImage: "battery.100.bolt",
                    tint: .orange,
                    // The gauge tracks the headline: this card is about health,
                    // not charge, so showing the charge level would misread.
                    accessory: snapshot.healthPercent.map { .gauge(Double($0) / 100) } ?? .none
                )
            }
            guard let pct else { return nil }
            return GlanceSignal(
                priority: .ambient,
                score: Double(100 - pct),
                headline: "Battery \(pct)%",
                detail: ambientDetail(advice),
                systemImage: snapshot.powerSource == .ac ? "battery.100.bolt" : "battery.75",
                tint: nil,
                accessory: gauge
            )
        }
    }

    /// The card headline always carries the charge level, since the gauge alone
    /// doesn't give a number — but never twice (`"Plug in now — 8%"` already
    /// has it).
    private func cardHeadline(_ advice: PowerAdvisor.Advice) -> String {
        guard let pct = snapshot.percentage else { return advice.headline }
        if advice.headline.contains("\(pct)%") { return advice.headline }
        return "\(advice.headline) · \(pct)%"
    }

    /// The quiet card's second line: what the advisor is watching, so even the
    /// ambient reading says something the battery menu doesn't.
    private func ambientDetail(_ advice: PowerAdvisor.Advice) -> String {
        if snapshot.state == .charging || snapshot.state == .charged {
            return advice.headline
        }
        if let minutes = advice.minutesUntilCritical, minutes > 0 {
            return "~\(formatMinutes(minutes)) before you'll want to plug in"
        }
        return advice.reason
    }

    /// A one-click "stop reminding me" on the card — only offered when charge
    /// reminders are actually on and not already snoozed.
    private func snoozeAction() -> GlanceSignal.QuickAction? {
        guard remindCharge else { return nil }
        if let until = reminderSnoozeUntil, Date() < until { return nil }
        return GlanceSignal.QuickAction(title: "Snooze 1h", systemImage: "bell.slash") { [weak self] in
            self?.snoozeReminders(minutes: 60)
        }
    }

    func popoverSection() -> AnyView { AnyView(PowerPopover(plugin: self)) }
    func settingsSection() -> AnyView { AnyView(PowerSettings(plugin: self)) }
}

// MARK: - Formatting helpers

private func formatMinutes(_ minutes: Int) -> String {
    guard minutes > 0 else { return "—" }
    let h = minutes / 60
    let m = minutes % 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    guard total >= 0 else { return "—" }
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "<1m"
}

// MARK: - Popover UI

private struct PowerPopover: View {
    let plugin: PowerPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !plugin.snapshot.hasBattery {
                noBattery
            } else {
                header
                if plugin.showSummary, let summary = healthSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if plugin.showAdvice, let advice = plugin.advice {
                    adviceCard(advice)
                }
                if plugin.showTip, let tip = plugin.batteryTip {
                    tipBanner(tip)
                }
                Divider()
                detailsGrid
                if plugin.history.count > 1 {
                    Divider()
                    chargeHistory
                }
            }
        }
    }

    private var noBattery: some View {
        HStack(spacing: 8) {
            Image(systemName: "powerplug")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No battery detected")
                    .font(.body.weight(.semibold))
                Text("This Mac runs on AC power only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        let snap = plugin.snapshot
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(snap.percentage.map { "\($0)%" } ?? "—")
                .font(GlanceStyle.hero(40, weight: .bold))
                .monospacedDigit()
            if snap.state == .charging || snap.state == .charged {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(GlanceStyle.positive)
                    .font(.title2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(stateText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let remaining = remainingText {
                    Text(remaining)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stateText: String {
        switch plugin.snapshot.state {
        case .charging: return "Charging"
        case .charged: return "Charged"
        case .discharging: return plugin.snapshot.powerSource == .battery ? "On battery" : "Not charging"
        case .unknown: return "—"
        }
    }

    private var remainingText: String? {
        let snap = plugin.snapshot
        if snap.state == .charging, let m = snap.timeToFullMinutes {
            return "\(formatMinutes(m)) to full"
        }
        if snap.state == .discharging, let m = snap.timeToEmptyMinutes {
            return "\(formatMinutes(m)) left"
        }
        return nil
    }

    /// A compact "battery health at a glance" line, computed outside any
    /// ViewBuilder. Returns nil when there's nothing meaningful to summarise.
    private var healthSummary: String? {
        let snap = plugin.snapshot
        guard snap.hasBattery else { return nil }
        var parts: [String] = []
        if snap.healthIsDegraded {
            parts.append("Service recommended")
        } else {
            parts.append("Good condition")
        }
        if let h = snap.healthPercent { parts.append("\(h)% health") }
        if let c = snap.cycleCount { parts.append("\(c) cycles") }
        return parts.joined(separator: " · ")
    }

    /// The headline recommendation: charge, unplug, cool down, or carry on —
    /// tinted by urgency so the answer reads before the sentence does.
    private func adviceCard(_ advice: PowerAdvisor.Advice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: adviceIcon(advice.action))
                .font(.callout)
                .foregroundStyle(adviceTint(advice))
            VStack(alignment: .leading, spacing: 2) {
                Text(advice.headline)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(adviceTint(advice))
                Text(advice.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let usageLine {
                    Text(usageLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if plugin.remindCharge, advice.isActionable {
                    snoozeControl
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(adviceTint(advice).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The evidence line under the advice: what this Mac's own usage looks like
    /// (drain rate, cycle pace), so the recommendation is visibly derived from
    /// the user's practice rather than a generic rule.
    private var usageLine: String? {
        var parts: [String] = []
        if let rate = plugin.usage.drainPerHour {
            parts.append(String(format: "%.0f%%/hour recently", rate))
        }
        if let pace = plugin.cyclePace {
            parts.append(pace)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Mirrors the Smart Panel card's snooze so the two never disagree about
    /// whether reminders are currently muted.
    @ViewBuilder
    private var snoozeControl: some View {
        if let until = plugin.reminderSnoozeUntil, until > Date() {
            HStack(spacing: 4) {
                Image(systemName: "bell.slash").font(.caption2)
                Text("Reminders snoozed until \(until, format: .dateTime.hour().minute())")
                    .font(.caption2)
                Button("Resume") { plugin.endSnooze() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
        } else {
            Button("Snooze 1h") { plugin.snoozeReminders(minutes: 60) }
                .buttonStyle(.borderless)
                .font(.caption2)
        }
    }

    private func adviceIcon(_ action: PowerAdvisor.Action) -> String {
        switch action {
        case .chargeNow, .chargeSoon: return "powerplug.fill"
        case .unplug: return "powerplug"
        case .coolDown: return "thermometer.high"
        case .steady: return "checkmark.circle"
        }
    }

    private func adviceTint(_ advice: PowerAdvisor.Advice) -> Color {
        switch advice.urgency {
        case .urgent: return .red
        case .notable: return .orange
        case .info: return advice.action == .steady ? .green : .accentColor
        }
    }

    /// A subtle, tinted card carrying the one actionable battery-usage tip.
    private func tipBanner(_ tip: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lightbulb.fill")
                .font(.caption)
                .foregroundStyle(GlanceStyle.highlight)
            Text(tip)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var detailsGrid: some View {
        let snap = plugin.snapshot
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            if plugin.showHealth {
                row("Health", snap.healthPercent.map { "\($0)%" } ?? "—",
                    tint: snap.healthIsDegraded ? .orange : nil)
            }
            if plugin.showCycles {
                row("Cycle count", snap.cycleCount.map(String.init) ?? "—")
            }
            if plugin.showTemperature {
                row("Temperature", temperatureText(snap),
                    tint: temperatureIsHot(snap) ? .orange : nil)
            }
            if plugin.showPower {
                row("Power draw", powerText(snap))
            }
            if plugin.showVoltage {
                row("Voltage", voltageText(snap))
            }
            if plugin.showCapacity {
                row("Full-charge capacity", capacityText(snap))
            }
            if plugin.showTimeOnBattery {
                row("Time on battery", timeOnBatteryText())
            }
            if plugin.showAdapter {
                row("Adapter", adapterText(snap))
            }
            if plugin.showCondition {
                row("Condition", snap.condition ?? "Normal",
                    tint: snap.healthIsDegraded ? .orange : nil)
            }
        }
    }

    // Value strings are computed in these helpers (never inline in the Grid
    // ViewBuilder, which cannot hold imperative let/if assignments).

    private func temperatureText(_ snap: PowerMetrics.Snapshot) -> String {
        snap.temperatureC.map { String(format: "%.1f°C", $0) } ?? "—"
    }

    private func temperatureIsHot(_ snap: PowerMetrics.Snapshot) -> Bool {
        guard let t = snap.temperatureC else { return false }
        return t >= Double(plugin.overheatThreshold)
    }

    private func powerText(_ snap: PowerMetrics.Snapshot) -> String {
        guard let w = snap.powerWatts, abs(w) >= 0.05 else { return "—" }
        let direction = w >= 0 ? "in" : "out"
        return String(format: "%.1f W %@", abs(w), direction)
    }

    private func voltageText(_ snap: PowerMetrics.Snapshot) -> String {
        guard let mV = snap.voltageMV else { return "—" }
        return String(format: "%.2f V", Double(mV) / 1000.0)
    }

    private func capacityText(_ snap: PowerMetrics.Snapshot) -> String {
        guard let mAh = snap.fullChargeCapacityMAh else { return "—" }
        return "\(mAh) mAh"
    }

    private func timeOnBatteryText() -> String {
        guard let interval = plugin.timeOnBattery else { return "—" }
        return formatDuration(interval)
    }

    private func adapterText(_ snap: PowerMetrics.Snapshot) -> String {
        if snap.powerSource == .ac, let w = snap.adapterWatts {
            return "\(w) W"
        }
        return snap.powerSource == .ac ? "Plugged" : "Unplugged"
    }

    private func row(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(tint ?? .primary)
                .gridColumnAlignment(.trailing)
        }
    }

    /// The most-recent samples the sparkline should draw, honouring the window.
    private var windowedHistory: [PowerPlugin.HistorySample] {
        let n = plugin.historyWindow
        return n >= plugin.history.count ? plugin.history : Array(plugin.history.suffix(n))
    }

    private var chargeHistory: some View {
        let shown = windowedHistory
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Charge history")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { plugin.historyWindow },
                    set: { plugin.historyWindow = $0 }
                )) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                    Text("120").tag(120)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Button {
                    plugin.clearHistory()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear charge history")
            }
            // A 0–100% scale with an axis label so the trend reads against the
            // full range.
            HStack(alignment: .center, spacing: 6) {
                VStack {
                    Text("100").font(GlanceStyle.micro).foregroundStyle(.tertiary)
                    Spacer()
                    Text("0").font(GlanceStyle.micro).foregroundStyle(.tertiary)
                }
                .frame(height: 40)
                PowerSparkline(values: shown.map { Double($0.percent) })
                    .frame(height: 40)
            }
            HStack {
                Text(rangeLabel(shown))
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("now")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// A left-axis time label for the oldest shown sample, computed outside the
    /// ViewBuilder. Falls back to a plain count when timestamps are unhelpful.
    private func rangeLabel(_ shown: [PowerPlugin.HistorySample]) -> String {
        guard let first = shown.first else { return "—" }
        let elapsed = Date().timeIntervalSince(first.time)
        if elapsed > 60 {
            return "-\(formatDuration(elapsed))"
        }
        return "last \(shown.count)"
    }
}

/// A minimal filled line chart of the recent charge percentages, fixed to a
/// 0–100 vertical scale so the trend is read against the full range.
private struct PowerSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            if values.count > 1 {
                let up = (values.last ?? 0) >= (values.first ?? 0)
                let color: Color = up ? .green : .orange
                let path = linePath(width: w, height: h)
                path
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .background(
                        filledPath(width: w, height: h)
                            .fill(color.opacity(0.15))
                    )
            } else {
                Rectangle().fill(.quaternary)
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func point(_ i: Int, width: CGFloat, height: CGFloat) -> CGPoint {
        let x = width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
        let clamped = min(max(values[i], 0), 100)
        let y = height * (1 - CGFloat(clamped / 100))
        return CGPoint(x: x, y: y)
    }

    private func linePath(width: CGFloat, height: CGFloat) -> Path {
        Path { p in
            for i in values.indices {
                let pt = point(i, width: width, height: height)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    private func filledPath(width: CGFloat, height: CGFloat) -> Path {
        Path { p in
            guard !values.isEmpty else { return }
            p.move(to: CGPoint(x: 0, y: height))
            for i in values.indices {
                p.addLine(to: point(i, width: width, height: height))
            }
            p.addLine(to: CGPoint(x: width, y: height))
            p.closeSubpath()
        }
    }
}

// MARK: - Settings UI

private struct PowerSettings: View {
    @Bindable var plugin: PowerPlugin

    var body: some View {
        SettingsPage("Detail rows", intro: "Choose which battery details appear in the popover.") {
            SettingsToggleRow("Charge advisor", isOn: $plugin.showAdvice)
            SettingsToggleRow("Health at a glance summary", isOn: $plugin.showSummary)
            SettingsToggleRow("Battery usage suggestion", isOn: $plugin.showTip)
            SettingsToggleRow("Battery health %", isOn: $plugin.showHealth)
            SettingsToggleRow("Cycle count", isOn: $plugin.showCycles)
            SettingsToggleRow("Temperature", isOn: $plugin.showTemperature)
            SettingsToggleRow("Power draw (watts)", isOn: $plugin.showPower)
            SettingsToggleRow("Voltage", isOn: $plugin.showVoltage)
            SettingsToggleRow("Full-charge capacity (mAh)", isOn: $plugin.showCapacity)
            SettingsToggleRow("Time on battery", isOn: $plugin.showTimeOnBattery)
            SettingsToggleRow("Power adapter", isOn: $plugin.showAdapter)
            SettingsToggleRow("Condition", isOn: $plugin.showCondition)

            Divider()

            SettingsSectionHeader("Charge history")
            Picker("Samples shown", selection: $plugin.historyWindow) {
                Text("Last 30").tag(30)
                Text("Last 60").tag(60)
                Text("Last 120").tag(120)
            }
            .pickerStyle(.segmented)
            Button("Clear history") { plugin.clearHistory() }

            Divider()

            SettingsSectionHeader("Low-battery alert")
            Stepper(value: $plugin.lowThreshold, in: 5...50, step: 5) {
                Text("Alert at \(plugin.lowThreshold)% or below")
                    .font(.callout)
            }
            SettingsHelp("The Smart Panel raises an urgent card when the battery drains to this level.")

            Divider()

            SettingsSectionHeader("Charge advisor")
            SettingsHelp("Advice blends your recent drain rate, battery health and temperature with the current charge.")
            SettingsToggleRow("Protect longevity (suggest unplugging at the ceiling)", isOn: $plugin.protectLongevity)
            // Each end is bounded by the other, keeping a 10-point band
            // between them: floor above ceiling has no coherent meaning and
            // leaves the advisor with no resting state.
            // The 50 floor is what keeps the control honest: `advise` hard-clamps
            // the ceiling to at least 50, so allowing a lower one here would show
            // "Charge ceiling 35%" while the advisor quietly used 50.
            Stepper(value: $plugin.chargeCeiling, in: max(50, plugin.chargeFloor + 10)...100, step: 5) {
                Text("Charge ceiling \(plugin.chargeCeiling)%")
                    .font(.callout)
            }
            .disabled(!plugin.protectLongevity)
            Stepper(value: $plugin.chargeFloor, in: 15...(plugin.chargeCeiling - 10), step: 5) {
                Text("Comfort floor \(plugin.chargeFloor)%")
                    .font(.callout)
            }
            SettingsHelp("Heavy usage, a high cycle count or degraded health automatically tightens both ends.")
            SettingsHelp("Cycle-life advice assumes an Apple silicon Mac (~\(PowerAdvisor.ratedCycles) rated cycles). Older Intel Macs were rated far lower, so their pacing would read optimistically.")

            Divider()

            SettingsSectionHeader("Charge reminders")
            SettingsToggleRow("Remind me to charge or unplug", isOn: $plugin.remindCharge)
            Stepper(value: $plugin.reminderLeadMinutes, in: 10...120, step: 10) {
                Text("Warn ~\(plugin.reminderLeadMinutes) min before \(plugin.lowThreshold)%")
                    .font(.callout)
            }
            .disabled(!plugin.remindCharge)
            Stepper(value: $plugin.reminderCooldownMinutes, in: 15...240, step: 15) {
                Text("At most one reminder every \(plugin.reminderCooldownMinutes) min")
                    .font(.callout)
            }
            .disabled(!plugin.remindCharge)
            SettingsHelp("The lead time is based on your measured drain rate, so a heavy session warns you earlier.")

            Divider()

            SettingsSectionHeader("Notifications")
            SettingsToggleRow("Notify when fully charged", isOn: $plugin.alertFullCharge)
            SettingsToggleRow("Warn on overheat", isOn: $plugin.alertOverheat)
            Stepper(value: $plugin.overheatThreshold, in: 30...50, step: 1) {
                Text("Overheat above \(plugin.overheatThreshold)°C")
                    .font(.callout)
            }
            .disabled(!plugin.alertOverheat)
            SettingsHelp("Best-effort banners with an audible cue; each fires once per crossing.")
        }
    }
}
