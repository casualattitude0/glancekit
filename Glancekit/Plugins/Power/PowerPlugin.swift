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

    /// The instant the Mac was last unplugged (moved onto battery), persisted so
    /// "time on battery" survives a relaunch while still unplugged. `nil` when
    /// on AC or unknown.
    private(set) var unplugDate: Date?

    /// Whether the current charge session already fired the full-charge alert,
    /// and whether an overheat alert is currently latched (hysteresis). Both are
    /// in-memory only — they should re-arm on relaunch.
    private var firedFullChargeAlert = false
    private var overheatLatched = false

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
    /// Percentage at/below which a discharging battery earns an urgent signal.
    var lowThreshold: Int {
        didSet { UserDefaults.standard.set(lowThreshold, forKey: "glancekit.power.lowThreshold") }
    }

    /// How many of the most-recent samples the sparkline draws (30 / 60 / 120).
    var historyWindow: Int {
        didSet { UserDefaults.standard.set(historyWindow, forKey: "glancekit.power.historyWindow") }
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
    private let unplugDateKey = "glancekit.power.unplugDate"

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
        lowThreshold = d.object(forKey: "glancekit.power.lowThreshold") as? Int ?? 10

        let savedWindow = d.object(forKey: "glancekit.power.historyWindow") as? Int ?? 120
        historyWindow = [30, 60, 120].contains(savedWindow) ? savedWindow : 120

        alertFullCharge = d.object(forKey: "glancekit.power.alertFullCharge") as? Bool ?? false
        alertOverheat = d.object(forKey: "glancekit.power.alertOverheat") as? Bool ?? false
        overheatThreshold = d.object(forKey: "glancekit.power.overheatThreshold") as? Int ?? 35

        if let data = d.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([HistorySample].self, from: data) {
            history = decoded
        }
        unplugDate = d.object(forKey: unplugDateKey) as? Date
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
        evaluateAlerts()
    }

    /// Empty the charge-history buffer and persisted copy.
    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    /// Elapsed time since the Mac was last unplugged, while still on battery.
    var timeOnBattery: TimeInterval? {
        guard snapshot.hasBattery,
              snapshot.powerSource == .battery,
              let start = unplugDate else { return nil }
        return max(0, Date().timeIntervalSince(start))
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
        } else if unplugDate != nil {
            unplugDate = nil
            UserDefaults.standard.removeObject(forKey: unplugDateKey)
        }
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
                PowerAlerts.notify(
                    title: "Battery fully charged",
                    body: "Your Mac has reached 100%. You can unplug it."
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
                    PowerAlerts.notify(
                        title: "Battery running warm",
                        body: String(format: "Battery is %.1f°C (threshold %d°C).",
                                     t, overheatThreshold)
                    )
                }
            } else if t < Double(overheatThreshold) - 2 {
                overheatLatched = false
            }
        }
    }

    /// Emphasises what the basic battery readout does NOT: battery *health*.
    /// A degraded battery earns an elevated card; a low, discharging battery is
    /// urgent with a gauge accessory.
    func currentSignal() -> GlanceSignal? {
        guard snapshot.hasBattery else { return nil }

        // Urgent: low and draining.
        if snapshot.state == .discharging, let pct = snapshot.percentage, pct <= lowThreshold {
            var detail = "On battery"
            if let mins = snapshot.timeToEmptyMinutes {
                detail = "~\(formatMinutes(mins)) remaining"
            }
            return GlanceSignal(
                priority: .urgent,
                score: Double(100 - pct),
                headline: "Battery \(pct)% · plug in",
                detail: detail,
                systemImage: "battery.25",
                tint: .red,
                accessory: .gauge(Double(pct) / 100)
            )
        }

        // Elevated: battery health degraded / service recommended.
        if snapshot.healthIsDegraded {
            let healthText = snapshot.healthPercent.map { "\($0)%" } ?? "low"
            let cond = snapshot.condition ?? "Service recommended"
            return GlanceSignal(
                priority: .elevated,
                score: Double(100 - (snapshot.healthPercent ?? 0)),
                headline: "Battery health \(healthText)",
                detail: cond,
                systemImage: "battery.100.bolt",
                tint: .orange
            )
        }

        return nil
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
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            if snap.state == .charging || snap.state == .charged {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.green)
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
                    Text("100").font(.system(size: 8)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("0").font(.system(size: 8)).foregroundStyle(.tertiary)
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Detail rows")
                .font(.headline)
            Text("Choose which battery details appear in the popover.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Health at a glance summary", isOn: $plugin.showSummary)
            Toggle("Battery health %", isOn: $plugin.showHealth)
            Toggle("Cycle count", isOn: $plugin.showCycles)
            Toggle("Temperature", isOn: $plugin.showTemperature)
            Toggle("Power draw (watts)", isOn: $plugin.showPower)
            Toggle("Voltage", isOn: $plugin.showVoltage)
            Toggle("Full-charge capacity (mAh)", isOn: $plugin.showCapacity)
            Toggle("Time on battery", isOn: $plugin.showTimeOnBattery)
            Toggle("Power adapter", isOn: $plugin.showAdapter)
            Toggle("Condition", isOn: $plugin.showCondition)

            Divider()

            Text("Charge history")
                .font(.headline)
            Picker("Samples shown", selection: $plugin.historyWindow) {
                Text("Last 30").tag(30)
                Text("Last 60").tag(60)
                Text("Last 120").tag(120)
            }
            .pickerStyle(.segmented)
            Button("Clear history") { plugin.clearHistory() }

            Divider()

            Text("Low-battery alert")
                .font(.headline)
            Stepper(value: $plugin.lowThreshold, in: 5...50, step: 5) {
                Text("Alert at \(plugin.lowThreshold)% or below")
                    .font(.callout)
            }
            Text("The Smart Panel raises an urgent card when the battery drains to this level.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Text("Notifications")
                .font(.headline)
            Toggle("Notify when fully charged", isOn: $plugin.alertFullCharge)
            Toggle("Warn on overheat", isOn: $plugin.alertOverheat)
            Stepper(value: $plugin.overheatThreshold, in: 30...50, step: 1) {
                Text("Overheat above \(plugin.overheatThreshold)°C")
                    .font(.callout)
            }
            .disabled(!plugin.alertOverheat)
            Text("Best-effort banners with an audible cue; each fires once per crossing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
